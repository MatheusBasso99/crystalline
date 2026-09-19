require "./crystalline/requires"
require "./crystalline/*"

if ARGV.includes?("--version")
  puts(Crystalline::VERSION)
  exit
end

if ARGV.includes?("--worker")
  Crystalline::Worker.start
  exit
end

Crystalline.init
