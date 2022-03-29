# frozen_string_literal: true

require_relative "github_reporter/version"
require "octokit"
require "set"
require "date"
require "csv"

module GithubReporter
  class Error < StandardError; end

  # @param since_date [String] "CCYY-MM-DD" format.
  # @param until_date [String] "CCYY-MM-DD" format.
  # @param repos [Array<String>] ["user/repo", "org/repo"]
  # @param kwargs [Hash]
  # @option kwargs [String] :access_token defaults `ENV.fetch("GITHUB_OAUTH_TOKEN")`
  # @option kwargs [#puts] :buffer defaults to `$stdout`
  # @option kwargs [Symbol] :format defaults to `:md`
  # @option labels_to_report [Array] :labels_to_report an array of label names for reporting columns
  #
  # @see Reporter::FORMATS_MAP for list of valid formats.
  # @todo Before we go a fetching, validate the format.
  def self.run(since_date:, until_date:, repos:, **kwargs)
    access_token = kwargs.fetch(:access_token) { ENV.fetch("GITHUB_OAUTH_TOKEN") }
    buffer = kwargs.fetch(:buffer) { $stdout }
    format = kwargs.fetch(:format) { :csv }
    labels_to_report = kwargs.fetch(:labels_to_report) { [] }

    scope = Scope.new(
      repository_names: repos,
      labels_to_report: labels_to_report,
      report_since_date: Time.parse("#{since_date}T00:00:00Z"),
      report_until_date: Time.parse("#{until_date}T00:00:00Z")
    )

    fetcher = Fetcher.new(scope: scope, access_token: access_token)
    data_store = fetcher.call

    Reporter.render(data_store: data_store, scope: scope, buffer: buffer, format: format)
  end

  # Store only the data that we want.  This also allows for nice and compact Marshaling.
  Issue = Struct.new(
    :closed_at,
    :commit_shas,
    :created_at,
    :html_url,
    :labels,
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
        labels: remote.labels.map(&:name),
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
    :labels,
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
        labels: remote.labels.map(&:name),
        number: remote.number,
        repository_name: repository.name,
        submitter: remote.user.login,
        title: remote.title,
        url: remote.pull_request.url, # Tricky remote, PRs have an issue and a pull_requests URL.
      )
    end
  end

  Repository = Struct.new(:client, :name, keyword_init: true)

  Scope = Struct.new(:labels_to_report, :repository_names, :report_since_date, :report_until_date, keyword_init: true)

  DataStore = Struct.new(:issues, :pulls, :labels, keyword_init: true)

  class Fetcher
    YE_OLE_DEPENDABOT_USERNAME = "dependabot[bot]".freeze

    def initialize(scope:, access_token: ENV.fetch("GITHUB_OAUTH_TOKEN"))
      @data_store = DataStore.new(issues: Set.new, pulls: Set.new, labels: Set.new)
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
          # We need to capture the next HREF  for pagination.
          href = client.last_response.rels[:next]&.href
          issues.each do |issue|
            next if issue.closed_at < scope.report_since_date
            next if issue.closed_at >= scope.report_until_date
            next if issue.user.login == YE_OLE_DEPENDABOT_USERNAME
            if issue.pull_request?
              pull = PullRequest.build_from(repository: repo, remote: issue)
              data_store.labels += pull.labels
              data_store.pulls << pull
            else
              issue = Issue.build_from(repository: repo, remote: issue)
              data_store.labels += issue.labels
              data_store.issues << issue
            end
          end
          issues = href ? client.get(href) : nil
        end
      end
      data_store
    end
  end

  module Reporter
    def self.render(format:, **kwargs)
      format = FORMATS_MAP.fetch(format) { Csv }
      format.new(**kwargs).render
    end

    class Base
      def initialize(data_store:, scope:, buffer: $stdout)
        @data_store = data_store
        @buffer = buffer
        @scope = scope
        @relations = Set.new
      end

      attr_reader :data_store, :buffer, :scope, :relations


      # @note Without a custom inspect, you'd see the @data_store.inspect as part of the output.
      # That overwhelms the output.
      def inspect
        "<##{self.class.name} { object_id: #{object_id} }>"
      end

      # @abstract
      # @return true when complete
      def render
        raise NotImplementedError
      end

      protected

      def format_date(date)
        return "" unless date
        date.strftime("%Y-%m-%d")
      end

      def relate_issue_to_prs(issue)
        issue.pull_request_urls.each do |url|
          self.relations << Relation.new(issue_url: issue.url, pull_url: url)
        end
      end

      def issue_urls_for(pull:)
        relations.select { |rel| rel.pull_url == pull.url }.map(&:issue_url)
      end
    end

    Relation = Struct.new(:issue_url, :pull_url, keyword_init: true)

    class Csv < Base

      def initialize(...)
        super(...)
        @csv_headers = ["NUMBER", "TITLE", "TYPE", "CREATED_ON", "CLOSED_ON", "SUBMITTER", "HTML_URL", "REALTED_NUMBERS"] + Array(scope.labels_to_report).compact.map { |l| "LABEL '#{l}'"}
      end
      attr_reader :csv_headers

      def render
        csv_string = CSV.generate(force_quotes: true, write_headers: true, headers: csv_headers) do |csv|
          push_issues_to(csv: csv)
          push_pulls_to(csv: csv)
        end
        buffer.puts(csv_string)
        true
      end

      private

      def push_issues_to(csv:)
        data_store.issues.each do |issue|
          relate_issue_to_prs(issue)
          csv << [
            issue.number,
            issue.title,
            "Issue",
            format_date(issue.created_at),
            format_date(issue.closed_at),
            issue.reporter,
            issue.html_url,
            urls_to_number_cell(urls: issue.pull_request_urls),
          ] + label_columns_for(issue)
        end
      end

      def push_pulls_to(csv:)
        data_store.pulls.each do |pull|
          csv << [
            pull.number,
            pull.title,
            "Pull Request",
            format_date(pull.created_at),
            format_date(pull.closed_at),
            pull.submitter,
            pull.html_url,
            urls_to_number_cell(urls: issue_urls_for(pull: pull))
          ] + label_columns_for(pull)
        end
      end

      def label_columns_for(node)
        scope.labels_to_report.map do |label|
          node.labels.include?(label) ? "true" : ""
        end
      end


      def urls_to_number_cell(urls:)
        return nil if urls.empty?

        # NOTE: By convention, the last slug of Github's pull or issue URLs are the number.
        numbers = urls.map { |url| url.split("/").last.to_i }

        return numbers.first if numbers.size == 1
        numbers.join("; ")
      end
    end

    class Markdown < Base
      def initialize(...)
        super(...)
        @visited_pull_urls = Set.new
      end

      attr_reader :visited_pull_urls

      def render
        raise "This is broken, perhaps I'll fix it later.  Use the CSV instead."
        render_header
        render_issues_section
        render_pull_requests_section
        true
      end

      private

      def render_header
        buffer.puts "# Issues and Pull Requests Closed\n\n"
        buffer.puts "- Run as of #{Time.now.iso8601}\n"
        buffer.puts "- From #{scope.report_since_date.strftime('%Y-%m-%d')} to #{scope.report_until_date.strftime('%Y-%m-%d')}"
        buffer.puts "- Number of Issues Closed: #{@data_store.issues.size}"
        buffer.puts "- Number of PR Closed: #{@data_store.pulls.size}\n\n"
      end

      def render_issues_section
        buffer.puts "## Issues Closed\n"
        data_store.issues.sort_by(&:number).each do |issue|
          buffer.puts "\n### #{issue.title}\n\n"
          buffer.puts "- [#{issue.repository_name}##{issue.number}](#{issue.html_url})"
          buffer.puts "- Reported by: [#{issue.reporter}](https://github.com/#{issue.reporter})"
          buffer.puts "- Created: #{issue.created_at.strftime('%Y-%m-%d')}"
          buffer.puts "- Closed: #{issue.closed_at.strftime('%Y-%m-%d')}"

          render_issues_pull_requests_for(issue: issue)
        end
      end

      def render_issues_pull_requests_for(issue:)
        relate_issue_to_prs(issue)
        pulls.ata_store.pulls.select { |pr| issue.pull_request_urls.include?(pr.url) }
        if pulls.any?
          buffer.puts "- Pull Requests:"
          pulls.each do |pull|
            buffer.puts "  - [#{pull.repository_name}##{pull.number}](#{pull.html_url}): #{pull.title}"
          end
        end
      end
      def render_pull_requests_section
        if not_visited.any?
          buffer.puts "\n\n## Pull Requests Merged without Corresponding Issue\n"
          not_visited.sort_by(&:number).each do |pr|
            buffer.puts "\n### #{pr.title}\n\n"
            buffer.puts "- [#{pr.repository_name}##{pr.number}](#{pr.html_url})"
            buffer.puts "- Created: #{pr.created_at.strftime('%Y-%m-%d')}"
            buffer.puts "- Closed: #{pr.closed_at.strftime('%Y-%m-%d')}"
            buffer.puts "- Submitter: [#{pr.submitter}](https://github.com/#{pr.submitter})"

            render_pull_requests_issue(pull: pull)
          end
        end
      end

      def render_pull_requests_issue(pull:)
        issue_urls = issue_urls_for(pull: pull)
        :todo
      end
    end

    FORMATS_MAP = {
      md: Markdown,
      markdown: Markdown,
      csv: Csv,
    }
  end
end
