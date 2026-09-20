require "./contracts"
require "./type_utils"

module Crystalline::Lightweight
  class SummaryType
    include JSON::Serializable

    getter name : String
    getter methods = [] of MethodInfo
    getter method_contracts = {} of String => Array(MethodContract)
    getter instance_vars = {} of String => Array(String)
    getter class_vars = {} of String => Array(String)

    def initialize(@name : String)
    end
  end

  class Summary
    include JSON::Serializable

    getter types = {} of String => SummaryType

    def initialize
    end

    def self.from_result(result : Crystal::Compiler::Result) : self
      new.tap do |summary|
        Builder.new { |type| summary.types[type.name] = type }.process(result.program)
      end
    end

    # Writes what `from_result(result).to_json(json)` would, without ever
    # holding the whole summary: each type is written as soon as it is
    # complete. On a large project the summary weighs 180 MB, which would
    # come on top of the typed program at the peak of the worker's memory.
    def self.write(result : Crystal::Compiler::Result, json : JSON::Builder) : Nil
      json.object do
        json.field("types") do
          json.object do
            Builder.new { |type| json.field(type.name) { type.to_json(json) } }.process(result.program)
          end
        end
      end
    end

    def type(name : String) : SummaryType?
      @types[name]?
    end
  end

  # Walks the types of a typed program and hands over the summary of each one
  # as soon as nothing more can be added to it.
  private class Summary::Builder
    # The types that are still being summarized.
    @types = {} of String => SummaryType
    @visited_types = Set(String).new
    # The name of each type met so far. `Type#to_s` is costly and the def
    # instances ask for the same names over and over: this makes them one
    # string each instead of one per mention.
    @type_names : Hash(Crystal::Type, String) = ({} of Crystal::Type => String).compare_by_identity

    def initialize(&@on_complete : SummaryType ->)
    end

    def process(program : Crystal::Program) : Nil
      process_type(program)
      # Whatever was summarized under a name that is not the one of a walked
      # type (the instance type of a metaclass met on its own, for instance).
      @types.each_value { |summary_type| @on_complete.call(summary_type) }
      @types.clear
    end

    private def process_type(type : Crystal::Type)
      # The type graph can contain cycles (metaclasses, generic
      # instantiations): never process the same type twice.
      return unless @visited_types.add?(name_of(type))
      if type.is_a?(Crystal::NamedType) || type.is_a?(Crystal::Program) || type.is_a?(Crystal::FileModule)
        type.types?.try &.each_value do |inner_type|
          process_type(inner_type)
        end
      end

      if type.is_a?(Crystal::GenericType)
        type.each_instantiated_type do |instance|
          process_type(instance)
        end
      end

      summarize_type(type)
      process_type(type.metaclass) if type.metaclass != type

      if type.is_a?(Crystal::DefInstanceContainer)
        type.def_instances.each_value do |typed_def|
          summarize_typed_def(type, typed_def)
        end
      end

      # A type is summarized under its own name, and so are the def instances
      # of its metaclass, which was walked just above: the entry is complete.
      @types.delete(name_of(type)).try { |summary_type| @on_complete.call(summary_type) }
    end

    private def summarize_type(type : Crystal::Type)
      return unless type.is_a?(Crystal::NamedType)

      summary_type = ensure_type(name_of(type))

      begin
        if type.allows_instance_vars?
          type.all_instance_vars.each do |name, ivar|
            summary_type.instance_vars[name] = TypeUtils.expand_type_names(ivar.type.to_s)
          end
        end
      rescue
      end

      metaclass = type.metaclass
      if metaclass.is_a?(Crystal::MetaclassType)
        begin
          metaclass.all_class_vars.each do |name, cvar|
            summary_type.class_vars[name] = TypeUtils.expand_type_names(cvar.type.to_s)
          end
        rescue
        end
      end
    end

    private def summarize_typed_def(type : Crystal::Type, typed_def : Crystal::Def)
      owner_name, class_method = owner_info(type)
      return_type = (typed_def.type? || typed_def.body.type?).try { |type| name_of(type) }
      return unless return_type

      summary_type = ensure_type(owner_name)
      method = MethodInfo.new(
        name: typed_def.name.to_s,
        owner: owner_name,
        args: typed_def.args.map { |arg|
          restriction = arg.type?.try { |type| name_of(type) } || arg.restriction.try(&.to_s)
          ArgInfo.new(name: arg.name.to_s, restriction: restriction)
        },
        return_type: return_type,
        class_method: class_method,
        doc: typed_def.doc,
        location: typed_def.location,
        name_location: typed_def.name_location,
        name_size: typed_def.name.to_s.size,
      )

      existing_index = summary_type.methods.index do |existing|
        existing.name == method.name &&
          existing.class_method == method.class_method &&
          existing.same_restrictions?(method)
      end

      if existing_index
        summary_type.methods[existing_index] = method
      else
        summary_type.methods << method
      end

      contracts = summary_type.method_contracts[method.name] ||= [] of MethodContract
      Contracts.derive(owner_name, method).each do |contract|
        contracts << contract unless contracts.includes?(contract)
      end
    end

    private def owner_info(type : Crystal::Type) : {String, Bool}
      if type.is_a?(Crystal::MetaclassType)
        {name_of(type.instance_type), true}
      else
        {name_of(type), false}
      end
    end

    private def name_of(type : Crystal::Type) : String
      @type_names.put_if_absent(type) { type.to_s }
    end

    private def ensure_type(name : String) : SummaryType
      @types[name] ||= SummaryType.new(name)
    end
  end
end
