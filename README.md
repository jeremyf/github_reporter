# GithubReporter

This gem is responsible for querying and reporting on a set of repositories over a period of time.  It's been quickly fleshed out as a proof of concept.

The idea is to connect issues and pull requests, but also to identify pull requests that might not have tracked to issues.

## Installation

TBD.

## Usage

At present there's not a tidy interface, but below is an example I used to build out the initial implementation.

Before you even get started you'll need a Github OAuth key.  Once you have that:

```sh
export GITHUB_OAUTH_TOKEN="<your-oauth-token>"
```

First we want to establishing the reporting scope:

```ruby
scope = GithubReporter::Scope.new(
  repository_names: ["forem/rfcs", "forem/forem"],
  report_since_date: Time.parse("2022-01-01T00:00:00Z"),
  report_until_date: Time.parse("2022-02-01T00:00:00Z")
)
```

Then we fetch the remote information:

```ruby
fetcher = GithubReporter::Fetcher.new(scope: scope)
data_store = fetcher.call
```

Since fetching the remote information can be expensive, I cached the fetched results locally:

```ruby
File.open("data_store_dump.txt", "w+") do |f|
  f.puts Marshal.dump(data_store)
end
```

I could then load the local cached values to run the report:

```ruby
data_store = Marshal.load(File.read("data_store_dump.txt"))

GithubReporter::Reporter.render(data_store: data_store, scope: scope, format: :csv)
```

Alternatively, if you don't want to use caching, you can use the `GithubReporter.run` method:

```ruby
GithubReporter.run(
  since_date: "2022-01-01",
  until_date: "2022-02-01",
  repos: ["forem/forem", "forem/rfcs"],
  format: :csv,
  auth_token: ENV.fetch["GITHUB_OAUTH_TOKEN"],
  buffer: $stdout
)
```

The above will live query Github and render output to given buffer.

Or if you'd prefer to write to a file:

```ruby
File.open("report.csv", "w+") do |fbuffer|
  GithubReporter.run(
    format: :csv,
    since_date: "2022-01-01",
    until_date: "2022-02-01",
    repos: ["forem/forem", "forem/rfcs"],
    auth_token: ENV.fetch("GITHUB_OAUTH_TOKEN"),
	data_store: "data_store.dump",
    buffer: fbuffer
  )
end
```

And because I've run this a few times, I added a script (which I need to update the dates).

```shell
$ GITHUB_OAUTH_TOKEN=<YOUR_TOKEN_HERE> bundle exec ruby ./to_run.rb
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jeremyf/github_reporter.
