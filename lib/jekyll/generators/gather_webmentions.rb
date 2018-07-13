# frozen_string_literal: false

#  (c) Aaron Gustafson
#  https://github.com/aarongustafson/jekyll-webmention_io
#  Licence : MIT
#
#  This generator gathers webmentions of your pages
#

require "time"

module Jekyll
  class GatherWebmentions < Generator
    safe true
    priority :high

    def generate(site)
      @site = site
      
      if @site.config.dig("url").include? 'localhost'
        Jekyll::WebmentionIO.log "msg", "Webmentions won’t be gathered on localhost."
        return
      end

      if @site.config.dig("webmentions", "pause_lookups") == true
        Jekyll::WebmentionIO.log "msg", "Webmention gathering is currently paused."
        return
      end

      @rescan = @site.config.dig("webmentions", "rescan")
      if @rescan
        require 'microformats'
        require 'sanitize'
        @sanitize_config = Sanitize::Config.merge(Sanitize::Config::BASIC,
         {protocols: {'a' => {'href' => ['dat']}},
          remove_contents: true,
          transformers: lambda {|env|
            # Remove empty elements
            node = env[:node]
            return unless node.elem?
            node.unlink unless node.content.strip.length > 0
         })
      end

      Jekyll::WebmentionIO.log "msg", "Beginning to gather webmentions of your posts. This may take a while."

      Jekyll::WebmentionIO.api_path = "mentions"
      # add an arbitrarily high perPage to trump pagination
      Jekyll::WebmentionIO.api_suffix = "&perPage=9999"

      @cached_webmentions = Jekyll::WebmentionIO.read_cached_webmentions "incoming"

      posts = Jekyll::WebmentionIO.gather_documents(@site)
      posts.each do |post|
        check_for_webmentions(post)
      end

      Jekyll::WebmentionIO.cache_webmentions "incoming", @cached_webmentions
    end # generate

    private

    def check_for_webmentions(post)
      Jekyll::WebmentionIO.log "info", "Checking for webmentions of #{post.url}."

      # get the last webmention
      last_webmention = @cached_webmentions.dig(post.url, @cached_webmentions.dig(post.url)&.keys&.last)

      # should we throttle?
      if post.respond_to? "date" # Some docs have no date
        if last_webmention && Jekyll::WebmentionIO.post_should_be_throttled?(post.data['title'], post.date, Date.parse(last_webmention.dig("raw", "verified_date")))
          Jekyll::WebmentionIO.log "info", "Throttling this post."
          return
        end
      end

      # Get the last id we have in the hash
      since_id = last_webmention ? last_webmention.dig("raw", "id") : false

      # Gather the URLs
      targets = get_webmention_target_urls(post)

      # execute the API
      response = Jekyll::WebmentionIO.get_response assemble_api_params(targets, since_id)
      webmentions = response.dig("links")
      if webmentions && !webmentions.empty?
        Jekyll::WebmentionIO.log "info", "Here’s what we got back:\n\n#{response.inspect}\n\n"
      else
        Jekyll::WebmentionIO.log "info", "No webmentions found."
      end

      cache_new_webmentions(post.url, response)
    end

    def get_webmention_target_urls(post)
      targets = []
      base_uri = @site.config["url"].chomp("/")
      uri = "#{base_uri}#{post.url}"
      targets.push(uri)

      # Redirection?
      gather_redirected_targets(post, uri, targets)

      # Domain changed?
      gather_legacy_targets(uri, targets)

      targets
    end

    def gather_redirected_targets(post, uri, targets)
      redirected = false
      if post.data.key? "redirect_from"
        if post.data["redirect_from"].is_a? String
          redirected = uri.sub post.url, post.data["redirect_from"]
          targets.push(redirected)
        elsif post.data["redirect_from"].is_a? Array
          post.data["redirect_from"].each do |redirect|
            redirected = uri.sub post.url, redirect
            targets.push(redirected)
          end
        end
      end
    end

    def gather_legacy_targets(uri, targets)
      if Jekyll::WebmentionIO.config.key? "legacy_domains"
        Jekyll::WebmentionIO.log "info", "adding legacy URIs"
        Jekyll::WebmentionIO.config["legacy_domains"].each do |domain|
          legacy = uri.sub @site.config["url"], domain
          Jekyll::WebmentionIO.log "info", "adding URI #{legacy}"
          targets.push(legacy)
        end
      end
    end

    def assemble_api_params(targets, since_id)
      api_params = targets.collect { |v| "target[]=#{v}" }.join("&")
      api_params << "&since_id=#{since_id}" if since_id
      api_params << "&sort-by=published"
      api_params
    end

    def cache_new_webmentions(post_uri, response)
      # Get cached webmentions
      webmentions = if @cached_webmentions.key? post_uri
                      @cached_webmentions[post_uri]
                    else
                      {}
                    end

      if response && response["links"]
        response["links"].reverse_each do |link|
          # Rescan the source using the Microformats gem. This is papering
          # over Webmention.io's sometimes odd 'content' area.
          if @rescan and link['data']
            begin
              mf = Microformats.parse(link['source'])
              link['data']['content'] = Sanitize.fragment(mf.entry.content.to_h[:html], @sanitize_config).
                gsub(/^\s+/, '')
            rescue
              Jekyll::WebmentionIO.log "info", "Could not rescan #{link['source']}"
            end
          end

          webmention = Jekyll::WebmentionIO::Webmention.new(link, @site)

          # Do we already have it?
          if webmentions.key? webmention.id
            next
          end

          # Add it to the list
          Jekyll::WebmentionIO.log "info", webmention.to_hash.inspect
          webmentions[webmention.id] = webmention.to_hash
        end # each link
      end # if response
      @cached_webmentions[post_uri] = webmentions
    end # process_webmentions
  end
end
