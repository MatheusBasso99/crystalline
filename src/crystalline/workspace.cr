require "uri"
require "yaml"
require "./text_document"
require "./progress"
require "./project"
require "./result_cache"
require "./lightweight/completion"
require "./lightweight/hover"
require "./lightweight/definitions"
require "./analysis/*"
require "./semantic"
require "./worker/*"

class Crystalline::Workspace
  # The previous compilation results, indexed by compilation entry point.
  @result_cache : Crystalline::ResultCache = Crystalline::ResultCache.new
  # Last successful semantic analysis results, used as a fast fallback for interactive features.
  # The cache survives document edits (only the compile-result dedup cache is invalidated);
  # semantic_cache_allowed? refuses to serve files that changed on disk after the compile.
  # The typed programs themselves live in worker processes: an entry goes away
  # when its entry point is compiled again, or once its worker has been idle for too long.
  @semantic_cache : Hash(String, Semantic::Provider) = {} of String => Semantic::Provider
  # The workers that are compiling right now, indexed by compilation entry point.
  @compiling = {} of String => Worker::Client
  # On-disk modification time of every source file at the last successful compile.
  @compiled_source_mtimes : Hash(String, Time) = {} of String => Time
  # Lightweight queries per open document, keyed by (uri, version). Each one
  # shares the project index and overlays only the document's own source, so
  # rebuilding one is cheap and must not happen per request.
  @query_cache = {} of String => {Int32, Crystalline::Lightweight::Query}
  @query_cache_lock = Mutex.new
  # Guards @opened_documents against the background query warm-up, which runs
  # on the compile execution context while the main context mutates the map.
  @documents_mutex = Mutex.new
  # The workspace filesystem uri.
  getter root_uri : URI?
  # A list of documents that are openened in the text editor.
  getter opened_documents = {} of String => TextDocument
  # A list of projects in this workspace
  getter projects = [] of Project

  def initialize(server : LSP::Server, root_uri : String?)
    if (@root_uri = root_uri.try &->URI.parse(String))
      @projects = Project.find_in_workspace_root @root_uri.not_nil!
      if @projects.size > 0
        LSP::Log.info {
          <<-LOG
          "[workspace] Found projects:
          #{@projects.map(&.root_uri.decoded_path).join('\n')}
          LOG
        }
      end
    end
  end

  def open_document(params : LSP::DidOpenTextDocumentParams)
    raw_uri = params.text_document.uri
    uri = URI.parse(raw_uri)
    project = project_for_file(uri)
    document = TextDocument.new(uri, project, params.text_document.text)
    @documents_mutex.synchronize { @opened_documents[raw_uri] = document }
  end

  def update_document(server : LSP::Server, params : LSP::DidChangeTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @opened_documents[file_uri]?

    document.try { |opened_document|
      content_changes = params.content_changes.map { |change|
        {change.text, change.range}
      }
      opened_document.update_contents(content_changes, version: params.text_document.version)
    }

    @result_cache.invalidate(file_uri)
    invalidate_project_caches(parsed_uri, document)
    @query_cache_lock.synchronize { @query_cache.delete(file_uri) }
  end

  def close_document(server : LSP::Server, params : LSP::DidCloseTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @documents_mutex.synchronize { @opened_documents.delete(params.text_document.uri) }
    @result_cache.invalidate(file_uri)
    # The parsed source index snapshots disk state: a saved or closed file
    # may have changed on disk, so the next query rebuilds it.
    project_for_file(parsed_uri).try(&.source_index = nil)
    invalidate_project_caches(parsed_uri, document)
    @query_cache_lock.synchronize { @query_cache.delete(file_uri) }
    Diagnostics.new.init_value(file_uri).publish(server) unless document.try(&.project?)
  end

  def save_document(server : LSP::Server, params : LSP::DidSaveTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @opened_documents[file_uri]?

    document.try &.mark_saved
    @result_cache.invalidate(file_uri)
    # The file changed on disk: the parsed source index is stale until it
    # is rebuilt (or the compile replaces it with the semantic index).
    project_for_file(parsed_uri).try(&.source_index = nil)
    invalidate_project_caches(parsed_uri, document)
  end

  def format_document(params : LSP::DocumentFormattingParams) : {String, TextDocument}?
    @opened_documents[params.text_document.uri]?.try { |document|
      {Crystal.format(document.contents), document}
    }
  rescue e
    # swallow exceptions silently
  end

  def format_document(params : LSP::DocumentRangeFormattingParams) : {String, TextDocument}?
    @opened_documents[params.text_document.uri]?.try { |document|
      range = params.range
      contents_lines = document.contents.lines(chomp: false)[range.start.line..range.end.line]
      contents_lines[-1] = contents_lines.last[...range.end.character] if range.end.character > 0
      contents_lines[0] = contents_lines.first[range.start.character...]
      {Crystal.format(contents_lines.join), document}
    }
  rescue e
    # swallow exceptions silently
  end

  # Run a top level semantic analysis to compute dependencies.
  def recalculate_dependencies(server, project)
    return unless (target = project.entry_point?)

    LSP::Log.info { "[compile] dependency recalculation: #{target.decoded_path}" }
    # The top-level pass gives the compiler-derived method restrictions and
    # block contracts within seconds, before the full compile finishes.
    compile_in_worker(server, target, project, wants_doc: true, top_level: true, ignore_diagnostics: true) do |_worker, _compiled, snapshot|
      publish_snapshot(project, snapshot)
      false
    end
  rescue
    nil
  end

  # Allow one compilation at a time.
  class_getter compilation_lock = Mutex.new

  # Use the crystal compiler to typecheck the program.
  def compile(
    server : LSP::Server,
    file_uri : URI,
    *,
    ignore_diagnostics = server.client_capabilities.ignore_diagnostics?,
    ignore_cached_result = false,
    wants_doc = false,
    top_level = false,
    discard_nil_cached_result = false,
  )
    @projects.each do |project|
      # If the project has less than 1 dependency, it could mean that the last
      # dependency calculation failed (likely because of a syntax error). So we
      # try again.
      recalculate_dependencies(server, project) if project.dependencies.size < 2
    end

    project = Project.best_fit_for_file(@projects, file_uri) || adopt(server, file_uri)

    # LSP::Log.info { "Compiling #{file_uri}, project: #{project.try(&.root_uri.decoded_path)}" }

    if project && (entry_point = project.entry_point?)
      target = entry_point
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building project",
        message: target.decoded_path
      )
    else
      # The file is not a project dependency.
      target = file_uri.not_nil!
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building",
        message: target.decoded_path
      )
    end

    target_string = target.to_s
    LSP::Log.info do
      source_kind = if top_level
                      "top-level"
                    else
                      "filesystem"
                    end
      "[compile] request: target=#{target.decoded_path} source=#{source_kind} ignore_cached=#{ignore_cached_result} discard_nil_cached=#{discard_nil_cached_result}"
    end
    # Check if we can serve the result from the cache.
    if !ignore_cached_result && @result_cache.exists?(target_string) && !@result_cache.invalidated?(target_string)
      cached_result = @result_cache.get(target_string)
      LSP::Log.info { "[compile] cache hit: #{target.decoded_path}" }
      return cached_result unless cached_result.nil? && discard_nil_cached_result
    end

    # This request supersedes the compile in flight for the same target, if
    # any: cancel it instead of waiting for an outdated result.
    @compiling[target_string]?.try do |outdated|
      LSP::Log.info { "[compile] superseded: cancelling the compile in flight for #{target.decoded_path}" }
      outdated.close
    end

    # Wait for pending compilations to finish…
    @@compilation_lock.synchronize do
      # Check again the cache in case some previous compilation that ran while waiting for the mutex to unlock is still valid.
      if !ignore_cached_result && @result_cache.exists?(target_string) && !@result_cache.invalidated?(target_string)
        cached_result = @result_cache.get(target_string)
        LSP::Log.info { "[compile] cache hit after wait: #{target.decoded_path}" }
        return cached_result unless cached_result.nil? && discard_nil_cached_result
      end

      # Buffered: when the compilation outlives the timeout below, nobody is left
      # to receive the result and an unbuffered channel would block its fiber forever.
      sync_channel = Channel(Semantic::Provider?).new(1)

      progress.report(server) do
        # Store the start of the compilation.
        compilation_start = @result_cache.monotonic_now
        result : Semantic::Provider? = nil
        message = "Completed with errors."

        LSP::Log.info { "[compile] analysis start: #{target.decoded_path}" }
        # One typed program per entry point at a time: the previous one is
        # released before its replacement starts growing.
        @semantic_cache.delete(target_string).try(&.close)
        compile_in_worker(server, target, project, wants_doc: wants_doc, top_level: top_level, ignore_diagnostics: ignore_diagnostics) do |worker, compiled, snapshot|
          message = "Completed successfully."

          # A client event may have invalidated the compile while it was
          # running: the worker is only kept when still relevant.
          next false if top_level || @result_cache.invalidated?(target_string, since: compilation_start)

          result = @semantic_cache[target_string] = worker
          stamp_compiled_sources(compiled.requires)
          publish_snapshot(project, snapshot)
          worker.close_when_idle
          true
        end
        message = "Cancelled." if result.nil? && @result_cache.invalidated?(target_string, since: compilation_start)
        # Store the result in the cache, unless a client event invalided the previous cache.
        # For instance if a compilation is running, but the user saved the document in the meantime (before completion)
        # then we discard the result because it is already outdated.
        @result_cache.set(target_string, result, unless_invalidated_since: compilation_start)
        message
      ensure
        sync_channel.send(result)
      end

      select
      when result = sync_channel.receive
        result
        # Just in case…
      when timeout 120.seconds
        progress.send_progress_end(server)
        nil
      end
    end
  end

  # A file under a project's root that the last dependency calculation did
  # not reach — one created since, typically — would compile as its own entry
  # point, without anything the project requires, and report errors that are
  # not there. Looks for it from the entry point once more before letting it
  # compile on its own; a file still missing is left alone until a compile
  # of the entry point reaches it.
  private def adopt(server : LSP::Server, file_uri : URI) : Project?
    path = file_uri.decoded_path
    project = Project.best_fit_for_file(@projects, file_uri, require_dependency: false)
    return unless project && (entry_point = project.entry_point?) && !project.outsiders.includes?(path)

    LSP::Log.info { "[compile] not a known dependency of #{entry_point.decoded_path}: #{path}" }
    recalculate_dependencies(server, project)
    unless project.dependencies.includes?(path)
      project.outsiders << path
      return
    end

    # The last compile of the entry point did not cover this file.
    @result_cache.invalidate(entry_point.to_s)
    project
  end

  # Compiles *target* in a worker process and, on success, yields the worker
  # along with what it reported and the lightweight snapshot it built. The
  # worker outlives the call only when the block returns true.
  private def compile_in_worker(server : LSP::Server, target : URI, project : Project?, *, wants_doc : Bool, top_level : Bool, ignore_diagnostics : Bool, & : Worker::Client, Worker::Compiled, Lightweight::Snapshot -> Bool) : Nil
    job = Worker::Job.new(
      entry: target.decoded_path,
      snapshot_path: File.tempname("crystalline-snapshot", ".json"),
      lib_path: project.try(&.default_lib_path),
      flags: project.try(&.flags) || [] of String,
      wants_doc: wants_doc,
      top_level: top_level,
    )
    worker = Worker::Client.spawn
    @compiling[target.to_s] = worker unless top_level
    compiled = worker.compile(job) do |diagnostics|
      Diagnostics.new(diagnostics).publish(server) unless ignore_diagnostics
    end
    # The requires of the entry point say which files make up the project,
    # and a compile that failed still reports the ones it reached.
    if compiled && project && target == project.entry_point?
      project.record_requires(compiled.requires, complete: compiled.success?)
    end
    # The snapshot is parsed off the event loop: it is large on a large project.
    if compiled && compiled.success? && (snapshot = Analysis.run_dedicated { Worker::Client.take_snapshot(job) })
      kept = yield worker, compiled, snapshot
    end
  ensure
    if worker
      @compiling.delete(target.to_s) if @compiling[target.to_s]?.same?(worker)
      worker.close unless kept
    end
    File.delete?(job.snapshot_path) if job
  end

  # Swaps in the lightweight data of a finished compile.
  private def publish_snapshot(project : Project?, snapshot : Lightweight::Snapshot) : Nil
    return unless project

    project.semantic_summary = snapshot.summary
    project.lightweight_index = snapshot.index
    # The project index changed: cached lightweight queries are stale.
    @query_cache_lock.synchronize { @query_cache.clear }
    spawn do
      warm_query_cache
      # The previous snapshot, and what reading the new one left behind, are
      # garbage by now. The server allocates too little between two compiles
      # for the collector to ever give their room back on its own.
      GC.collect_and_unmap
    end
  end

  private def project_for_file(file_uri : URI) : Project?
    Project.best_fit_for_file(@projects, file_uri)
  end

  private def lightweight_query_for(document : TextDocument) : Crystalline::Lightweight::Query?
    cache_key = document.uri.to_s
    @query_cache_lock.synchronize do
      if cached = @query_cache[cache_key]?
        return cached[1] if cached[0] == document.version_number
      end
    end

    query = if project = document.project? || Project.best_fit_for_file(@projects, document.uri, require_dependency: false)
              if project_index = project.lightweight_index
                if document.dirty? || !project.dependencies.includes?(document.uri.decoded_path)
                  # The buffer diverges from what was compiled, or the file is
                  # not part of the compiled program at all (e.g. a new file
                  # not yet required): overlay the source index on top of the
                  # project index. The overlay is a small per-file index; the
                  # project index is shared across documents instead of being
                  # copied per keystroke.
                  source_index = Crystalline::Lightweight::Index.from_source(fix_source(document.contents), document.uri.decoded_path)
                  Crystalline::Lightweight::Query.new(project_index, project.semantic_summary, secondary: Crystalline::Lightweight::PreludeIndex.get, overlay: source_index)
                else
                  # A clean dependency buffer matches the compiled sources:
                  # the project index is authoritative, no overlay needed.
                  Crystalline::Lightweight::Query.new(project_index, project.semantic_summary, secondary: Crystalline::Lightweight::PreludeIndex.get)
                end
              end
            end

    query ||= begin
      source_index = Crystalline::Lightweight::Index.from_source(fix_source(document.contents), document.uri.decoded_path)
      if source_index
        # Before the project index exists (no compile yet), the base index
        # is the project's own source files parsed from disk, so receivers
        # of project types (e.g. `workspace`) resolve from the very first
        # keystroke. The stdlib prelude is layered underneath.
        project_index = document.project?.try(&.source_index)
        project_index ||= Project.best_fit_for_file(@projects, document.uri, require_dependency: false).try(&.source_index)
        if project_index
          if prelude = Crystalline::Lightweight::PreludeIndex.get
            Crystalline::Lightweight::Query.new(project_index, secondary: prelude, overlay: source_index)
          else
            Crystalline::Lightweight::Query.new(project_index, overlay: source_index)
          end
        elsif prelude = Crystalline::Lightweight::PreludeIndex.get
          Crystalline::Lightweight::Query.new(prelude, overlay: source_index)
        else
          Crystalline::Lightweight::Query.new(source_index)
        end
      end
    end

    @query_cache_lock.synchronize do
      if query
        @query_cache[cache_key] = {document.version_number, query}
      else
        @query_cache.delete(cache_key)
      end
    end
    query
  end

  # Rebuild the cached lightweight query of every opened document, so the
  # first interactive request after a compile does not pay the project-index
  # merge. Runs in the background, on the compile context: snapshot the open
  # documents under a lock before touching them.
  private def warm_query_cache
    documents = @documents_mutex.synchronize { @opened_documents.values.dup }
    documents.each do |document|
      lightweight_query_for(document)
    end
  end

  private def semantic_cache_key(file_uri : URI) : String
    if (project = project_for_file(file_uri)) && (entry_point = project.entry_point?)
      entry_point.to_s
    else
      file_uri.to_s
    end
  end

  private def invalidate_project_caches(file_uri : URI, document : TextDocument?)
    cache_keys = Set(String).new

    document.try(&.project?).try(&.entry_point?).try { |entry|
      cache_keys << entry.to_s
    }

    project_for_file(file_uri).try(&.entry_point?).try { |entry|
      cache_keys << entry.to_s
    }

    # The semantic cache is intentionally kept across edits: it holds the
    # last successful compile and semantic_cache_allowed? refuses to serve
    # it for files that changed since.
    cache_keys.each do |cache_key|
      @result_cache.invalidate(cache_key)
    end
  end

  private def semantic_cache_allowed?(file_uri : URI) : Bool
    document = @opened_documents[file_uri.to_s]?
    return false if document.try(&.dirty?)

    # The semantic cache holds the last successful compile. Only serve it
    # for files whose on-disk content is the one that was compiled, so a
    # save whose compile failed (or an external edit) cannot poison other
    # files' requests with stale results.
    return true unless file_uri.scheme == "file"

    path = file_uri.decoded_path
    mtime = @compiled_source_mtimes[path]?
    return true unless mtime

    File.info(path).modification_time == mtime
  rescue File::NotFoundError
    false
  end

  private def stamp_compiled_sources(requires : Array(String))
    stamps = {} of String => Time
    requires.each do |filename|
      begin
        stamps[filename] = File.info(filename).modification_time
      rescue File::NotFoundError
      end
    end
    @compiled_source_mtimes = stamps
  end

  def hover(server : LSP::Server, file_uri : URI, position : LSP::Position)
    if text_document = @opened_documents[file_uri.to_s]?
      source = fix_source(text_document.contents)
      if query = lightweight_query_for(text_document)
        hover, reason = Crystalline::Lightweight::Hover.hover_and_reason(source, position.line, position.character, query)
        if hover
          LSP::Log.info { "[hover] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
          return hover
        end

        LSP::Log.info { "[hover] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
      else
        LSP::Log.info { "[hover] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=no lightweight query" }
      end
    end

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[hover] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[hover] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[hover] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
    result.hover(file_uri, position)
  rescue
    nil
  end

  def definitions(server : LSP::Server, file_uri : URI, position : LSP::Position)
    if text_document = @opened_documents[file_uri.to_s]?
      source = fix_source(text_document.contents)
      query = lightweight_query_for(text_document)
      locations, reason = Crystalline::Lightweight::Definitions.definitions_and_reason(source, file_uri, position.line, position.character, query)
      if locations
        LSP::Log.info { "[definitions] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
        return locations
      end

      LSP::Log.info { "[definitions] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
    end

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[definitions] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[definitions] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[definitions] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
    result.definitions(file_uri, position)
  rescue
    nil
  end

  def completion(server : LSP::Server, file_uri : URI, position : LSP::Position, trigger_character : String?)
    text_document = @opened_documents[file_uri.to_s]?
    return unless text_document

    document_lines = fix_source(text_document.contents).lines(chomp: false)
    completion_context = CompletionContext.detect(document_lines[position.line], position.character, trigger_character)
    return unless completion_context

    if query = lightweight_query_for(text_document)
      completion_items, reason = Crystalline::Lightweight::Completion.complete_and_reason(document_lines.join, position.line, completion_context, query)
      if completion_items
        # A resolved completion may legitimately be empty (e.g. no ivars
        # match a fragment): only a miss (nil) falls through to the
        # compiled fallback.
        LSP::Log.info { "[completion] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character} items=#{completion_items.size}" }
        return build_completion_list(completion_items)
      end

      LSP::Log.info { "[completion] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
    else
      LSP::Log.info { "[completion] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=no lightweight query" }
    end

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[completion] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[completion] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[completion] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
    result.completion(file_uri, position, document_lines[position.line], trigger_character).try do |completion_items|
      build_completion_list(completion_items)
    end
  rescue
    nil
  end

  private def build_completion_list(completion_items : Array(LSP::CompletionItem)) : LSP::CompletionList
    selected_element_index = nil
    completion_items.each_with_index do |elt, i|
      sort_text = elt.sort_text || elt.label
      selected_element_index ||= i
      target = completion_items[selected_element_index].try { |e| e.sort_text || e.label }
      if (sort_text <=> target) < 0
        selected_element_index = i
      end
    end

    if selected_element_index
      selected_element = completion_items[selected_element_index]
      selected_element.preselect = true
      completion_items[selected_element_index] = selected_element
    end

    LSP::CompletionList.new(
      is_incomplete: false,
      items: completion_items,
    )
  end

  def document_symbols(server : LSP::Server, file_uri : URI)
    @opened_documents[file_uri.to_s]?.try { |text_document|
      parser = Crystal::Parser.new(fix_source(text_document.contents))
      parser.filename = file_uri.decoded_path
      parser.wants_doc = false

      Analysis::DocumentSymbolsVisitor.new.tap { |visitor|
        parser.parse.accept(visitor)
      }.symbols
    }
  end

  # The semantic tokens of an open document. Computed from the buffer itself:
  # the edits and ranges of the client apply to it, not to the repaired text.
  def semantic_tokens(file_uri : URI) : LSP::SemanticTokens?
    @opened_documents[file_uri.to_s]?.try { |text_document|
      Crystalline::Lightweight::SemanticTokens.tokens(text_document.contents)
    }
  end

  def folding_ranges(file_uri : URI) : Array(LSP::FoldingRange)?
    @opened_documents[file_uri.to_s]?.try { |text_document|
      Crystalline::Lightweight::FoldingRange.ranges(text_document.contents)
    }
  end

  def selection_ranges(file_uri : URI, positions : Array(LSP::Position)) : Array(LSP::SelectionRange)?
    @opened_documents[file_uri.to_s]?.try { |text_document|
      lines = text_document.contents.lines(chomp: false)
      Crystalline::Lightweight::SelectionRange.ranges(text_document.contents, positions, lines)
    }
  end

  def document_highlights(file_uri : URI, position : LSP::Position) : Array(LSP::DocumentHighlight)?
    @opened_documents[file_uri.to_s]?.try { |text_document|
      Crystalline::Lightweight::DocumentHighlight.highlights(text_document.contents, position.line, position.character)
    }
  end

  def signature_help(file_uri : URI, position : LSP::Position) : LSP::SignatureHelp?
    return unless text_document = @opened_documents[file_uri.to_s]?
    return unless query = lightweight_query_for(text_document)

    Crystalline::Lightweight::SignatureHelp.help(text_document.contents, position.line, position.character, query)
  end

  # The symbols of the project sources matching *query*.
  def workspace_symbols(query : String) : Array(LSP::SymbolInformation)
    @projects.flat_map { |project|
      if index = project.lightweight_index || project.source_index
        Crystalline::Lightweight::WorkspaceSymbol.symbols(index, project.root_uri.decoded_path, query)
      else
        [] of LSP::SymbolInformation
      end
    }.uniq
  end

  private def fix_source(source : String) : String
    # LSP::Log.info { "Fixing source: #{source}" }
    Crystal::Parser.parse(source)
    # LSP::Log.info { "No need to fix source!" }
    source
  rescue
    fixed_source = BrokenSourceFixer.fix(source)
    # LSP::Log.info { "Fixed source: #{fixed_source}" }
    fixed_source
  end
end
