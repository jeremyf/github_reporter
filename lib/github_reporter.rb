# frozen_string_literal: true

require_relative "github_reporter/version"
require "octokit"
require "set"
require "date"

module GithubReporter
  class Error < StandardError; end


  # @param since_date [String] "CCYY-MM-DD" format.
  # @param until_date [String] "CCYY-MM-DD" format.
  # @param repos [Array<String>] ["user/repo", "org/repo"]
  # @param kwargs [Hash]
  # @option kwargs [String] :access_token defaults `ENV.fetch("GITHUB_OAUTH_TOKEN")`
  # @option kwargs [#puts] :buffer defaults to `$stdout`
  #
  # @see REPOSITORIES_TO_QUERY
  def self.run(since_date:, until_date:, repos:, **kwargs)
    access_token = kwargs.fetch(:access_token) { ENV.fetch("GITHUB_OAUTH_TOKEN") }
    buffer = kwargs.fetch(:buffer) { $stdout }

    scope = Scope.new(
      repository_names: repos,
      report_since_date: Time.parse("#{since_date}T00:00:00Z"),
      report_until_date: Time.parse("#{until_date}T00:00:00Z")
    )

    fetcher = Fetcher.new(scope: scope, access_token: access_token)
    data_store = fetcher.call

    Reporter.new(data_store: data_store, scope: scope, buffer: buffer).render
  end

  # Store only the data that we want.  This also allows for nice and compact Marshaling.
  Issue = Struct.new(
    :closed_at,
    :commit_shas,
    :created_at,
    :html_url,
    :number,
    :pull_request_urls,
    :reporter,
    :repository_name,
    :title,
    :url,
    keyword_init: true
  ) do
    def self.build_from(remote:, repository:)
      timeline = repository.client.issue_timeline(repository.name, remote.number)

      # While not fully necessary, this does show commits that relate to this.
      commit_shas = timeline.map(&:commit_id).compact
      pull_request_urls = timeline.map(&:source).compact.map { |s| s&.issue&.pull_request&.url }.compact
      new(
        closed_at: remote.closed_at,
        commit_shas: commit_shas,
        created_at: remote.created_at,
        html_url: remote.html_url,
        number: remote.number,
        pull_request_urls: pull_request_urls,
        reporter: remote.user.login,
        repository_name: repository.name,
        title: remote.title,
        url: remote.url,
      )
    end
  end

  # Store only the data that we want.  This also allows for nice and compact Marshaling.
  PullRequest = Struct.new(
    :closed_at,
    :commit_shas,
    :created_at,
    :html_url,
    :number,
    :repository_name,
    :submitter,
    :title,
    :url,
    keyword_init: true
  ) do
    def self.build_from(remote:, repository:)
      commits = repository.client.pull_commits(repository.name, remote.number)
      pull_request = repository.client.get(remote.pull_request.url)
      commit_shas = commits.map(&:sha) + [pull_request.merge_commit_sha]
      new(
        closed_at: remote.closed_at,
        commit_shas: commit_shas,
        created_at: remote.created_at,
        html_url: remote.html_url,
        number: remote.number,
        repository_name: repository.name,
        submitter: remote.user.login,
        title: remote.title,
        url: remote.pull_request.url, # Tricky remote, PRs have an issue and a pull_requests URL.
      )
    end
  end

  Repository = Struct.new(:client, :name, keyword_init: true)

  Scope = Struct.new(:repository_names, :report_since_date, :report_until_date, keyword_init: true)

  DataStore = Struct.new(:issues, :pulls, keyword_init: true)

  class Fetcher
    YE_OLE_DEPENDABOT_USERNAME = "dependabot[bot]".freeze

    def initialize(scope:, access_token: ENV.fetch("GITHUB_OAUTH_TOKEN"))
      @data_store = DataStore.new(issues: Set.new, pulls: Set.new)
      @client = Octokit::Client.new(
        access_token: access_token,
        per_page: 50
      )
      @scope = scope
    end
    attr_reader :client, :data_store, :scope

    def call
      scope.repository_names.each do |repository_name|
        repo = Repository.new(client: client, name: repository_name)
        issues = client.issues(repo.name, state: "closed", sort: "updated", since: scope.report_since_date.iso8601)
        while issues
          issues.each do |issue|
            next if issue.closed_at < scope.report_since_date
            next if issue.closed_at >= scope.report_until_date

            next if issue.user.login == YE_OLE_DEPENDABOT_USERNAME

            if issue.pull_request?
              data_store.pulls << PullRequest.build_from(repository: repo, remote: issue)
            else
              data_store.issues << Issue.build_from(repository: repo, remote: issue)
            end
          end
          href = client.last_response.rels[:next]&.href
          issues = href ? client.get(href) : nil
        end
      end
      data_store
    end
  end

  class Reporter
    def initialize(data_store:, scope:, buffer: $stdout)
      @data_store = data_store
      @visited_pull_requests = Set.new
      @buffer = buffer
      @scope = scope
    end

    def render
      render_header
      render_issues_section
      render_pull_requests_section
    end

    private

    def render_header
      @buffer.puts "# Issues and Pull Requests Closed\n\n"
      @buffer.puts "- Run as of #{Time.now.iso8601}\n"
      @buffer.puts "- From #{@scope.report_since_date.strftime('%Y-%m-%d')} to #{@scope.report_until_date.strftime('%Y-%m-%d')}"
      @buffer.puts "- Number of Issues Closed: #{@data_store.issues.size}"
      @buffer.puts "- Number of PR Closed: #{@data_store.pulls.size}\n\n"
    end

    def render_issues_section
      @buffer.puts "## Issues Closed\n"
      @data_store.issues.sort_by(&:number).each do |issue|
        @buffer.puts "\n### #{issue.title}\n\n"
        @buffer.puts "- [#{issue.repository_name}##{issue.number}](#{issue.html_url})"
        @buffer.puts "- Reported by: [#{issue.reporter}](https://github.com/#{issue.reporter})"
        @buffer.puts "- Created: #{issue.created_at.strftime('%Y-%m-%d')}"
        @buffer.puts "- Closed: #{issue.closed_at.strftime('%Y-%m-%d')}"

        render_issues_pull_requests_for(issue: issue)
      end
    end

    def render_issues_pull_requests_for(issue:)
      issue_prs = @data_store.pulls.select { |pr| issue.pull_request_urls.include?(pr.url) }
      if issue_prs.any?
        @buffer.puts "- Pull Requests:"
        issue_prs.each do |pr|
          @visited_pull_requests << pr
          @buffer.puts "  - [#{pr.repository_name}##{pr.number}](#{pr.html_url}): #{pr.title}"
        end
      end
    end

    def visit_pull_request_from_timeframe(url:)
      pr = @data_store.pulls.detect { |pr| pr.url == url }
      if pr
        @visited_pull_requests << pr
        yield(pr)
      end
    end

    def render_pull_requests_section
      not_visited = @data_store.pulls - @visited_pull_requests
      if not_visited.any?
        @buffer.puts "\n\n## Pull Requests Merged without Corresponding Issue\n"
        not_visited.sort_by(&:number).each do |pr|
          @buffer.puts "\n### #{pr.title}\n\n"
          @buffer.puts "- [#{pr.repository_name}##{pr.number}](#{pr.html_url})"
          @buffer.puts "- Created: #{pr.created_at.strftime('%Y-%m-%d')}"
          @buffer.puts "- Closed: #{pr.closed_at.strftime('%Y-%m-%d')}"
          @buffer.puts "- Submitter: [#{pr.submitter}](https://github.com/#{pr.submitter})"
        end
      end
    end
  end
end
