module GC
  def self.init
    # LibGC.set_free_space_divisor(10)
    # LibGC.set_force_unmap_on_gcollect(1)
    previous_def
  end

  # Runs the block with another free space divisor: the higher it is, the
  # more often the collector runs instead of growing the heap.
  def self.with_free_space_divisor(divisor : Int, &)
    previous = LibGC.get_free_space_divisor
    LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
    begin
      yield
    ensure
      LibGC.set_free_space_divisor(previous)
    end
  end

  # Collects, then hands the free heap blocks back to the operating system.
  # The collector only does so on its own while it keeps collecting, that is
  # while the program keeps allocating: a process that goes quiet right after
  # a burst of allocations would sit on the peak of its heap.
  def self.collect_and_unmap : Nil
    # A block is unmapped once it has stayed free for more than one
    # collection: the first one frees it, the third one unmaps it.
    2.times { LibGC.collect }
    LibGC.gcollect_and_unmap
  end
end

lib LibGC
  fun set_free_space_divisor = GC_set_free_space_divisor(size : LibGC::Word) : Void
  fun get_free_space_divisor = GC_get_free_space_divisor : LibGC::Word
  fun enable_incremental = GC_enable_incremental : Void
  fun set_force_unmap_on_gcollect = GC_set_force_unmap_on_gcollect(size : LibC::Int) : Void
  fun gcollect_and_unmap = GC_gcollect_and_unmap : Void
end
