# frozen_string_literal: false

require "json"

module Jekyll
  module Commands
    class WebmentionCommand < Command
      def self.init_with_program(prog)
        prog.command(:webmention) do |c|
          c.syntax "webmention"
          c.description "Sends queued webmentions"

          c.action { |args, options| process args, options }
        end
      end

      def self.process(_args = [], _options = {})
        if File.exist? "#{Jekyll::WebmentionIO.cache_folder}/#{Jekyll::WebmentionIO.file_prefix}sent.yml"
          Jekyll::WebmentionIO.log "error", "Your outgoing webmentions queue needs to be upgraded. Please re-build your project."
        end
        attempts, count = 0, 0
        cached_outgoing = Jekyll::WebmentionIO.get_cache_file_path "outgoing"
        if File.exist?(cached_outgoing)
          outgoing = open(cached_outgoing) { |f| YAML.load(f) }
          outgoing.each do |source, targets|
            post_timestamp = targets.delete("timestamp")
            targets.each do |target, response|
              # should we throttle?
              if response.is_a? Hash # Some docs have no date
                timestamp = response['timestamp']
                if timestamp && Jekyll::WebmentionIO.post_should_be_throttled?(target, post_timestamp, timestamp.to_date)
                  Jekyll::WebmentionIO.log "info", "Throttling #{target}."
                else
                  response = false
                end
              end
              next unless response == false

              if target.index("//").zero?
                target = "http:#{target}"
              end
              endpoint = Jekyll::WebmentionIO.get_webmention_endpoint(target)
              response = nil
              if endpoint
                response = Jekyll::WebmentionIO.webmention(source, target, endpoint)
                if response
                  response = JSON.parse response rescue ""
                  count += 1
                end
              end
              outgoing[source][target] = {'timestamp' => Time.now, 'response' => response}
              attempts += 1
            end
            targets['timestamp'] = post_timestamp
          end
          if count.positive?
            File.open(cached_outgoing, "w") { |f| YAML.dump(outgoing, f) }
          end
          Jekyll::WebmentionIO.log "msg", "#{count} webmentions sent, #{attempts} attemped."
        end # file exists (outgoing)
      end # def process
    end # WebmentionCommand
  end # Commands
end # Jekyll
