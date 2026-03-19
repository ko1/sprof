Gem::Specification.new do |spec|
  spec.name          = "sprof"
  spec.version       = "0.1.0"
  spec.authors       = ["Koichi Sasada"]
  spec.summary       = "Safepoint-based sampling profiler for Ruby"
  spec.description   = "A safepoint-based sampling profiler that uses thread CPU time deltas as weights to correct safepoint bias."
  spec.homepage      = "https://github.com/ko1/sprof"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.files         = Dir["lib/**/*.rb", "ext/**/*.{c,h,rb}", "exe/*", "LICENSE", "README.md"]
  spec.bindir        = "exe"
  spec.executables   = ["sprof"]
  spec.extensions    = ["ext/sprof/extconf.rb"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "test-unit", "~> 3.6"
end
