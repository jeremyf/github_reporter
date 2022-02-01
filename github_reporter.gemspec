# frozen_string_literal: true

require_relative "lib/github_reporter/version"

Gem::Specification.new do |spec|
  spec.name = "github_reporter"
  spec.version = GithubReporter::VERSION
  spec.authors = ["Jeremy Friesen"]
  spec.email = ["jeremy.n.friesen@gmail.com"]

  spec.summary       = %q{Run reports on Github repositories}
  spec.description   = %q{Run reports on Github repositories}
  spec.homepage      = "https://github.com/jeremyf/github_reporter"
  spec.required_ruby_version = ">= 3.0.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/jeremyf/github_reporter/"
  spec.metadata["changelog_uri"] = "https://github.com/jeremyf/github_reporter/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
  spec.add_dependency "octokit"
  spec.add_development_dependency "debug", ">= 1.0.0"
end
