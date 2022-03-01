require_relative "lib/github_reporter"

File.open("report-2022-02.csv", "w+") do |fbuffer|
  GithubReporter.run(
    format: :csv,
    since_date: "2022-02-01",
    until_date: "2022-03-01",
    repos: ["forem/forem", "forem/rfcs"],
    auth_token: ENV.fetch("GITHUB_OAUTH_TOKEN"),
    data_store: "data_store.dump",
    buffer: fbuffer
  )
end