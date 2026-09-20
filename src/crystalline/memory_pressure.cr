{% if flag?(:darwin) %}
  lib LibC
    fun sysctlbyname(name : Char*, oldp : Void*, oldlenp : SizeT*, newp : Void*, newlen : SizeT) : Int
  end
{% end %}

# Tells when the operating system is running short of memory, so that what is
# only kept for convenience can be let go.
module Crystalline::MemoryPressure
  # The share of the last ten seconds that some task spent waiting for memory
  # above which a Linux system is considered short of it.
  STALLED_PERCENT = 10.0

  # False wherever the system does not tell.
  def self.high? : Bool
    {% if flag?(:darwin) %}
      # 1 is normal, 2 is a warning and 4 is critical.
      level = 0
      size = LibC::SizeT.new(sizeof(Int32))
      LibC.sysctlbyname("kern.memorystatus_vm_pressure_level", pointerof(level), pointerof(size), nil, 0) == 0 && level >= 2
    {% elsif flag?(:linux) %}
      stalled?(File.read("/proc/pressure/memory"))
    {% else %}
      false
    {% end %}
  rescue
    false
  end

  # *pressure* is the content of `/proc/pressure/memory`:
  # `some avg10=0.00 avg60=0.00 avg300=0.00 total=0`, then the same for `full`.
  def self.stalled?(pressure : String) : Bool
    average = pressure.match(/^some avg10=([\d.]+)/m).try(&.[1].to_f?)
    !average.nil? && average >= STALLED_PERCENT
  end
end
