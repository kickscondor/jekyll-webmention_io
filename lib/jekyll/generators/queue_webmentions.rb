# frozen_string_literal: false

#  (c) Aaron Gustafson
#  https://github.com/aarongustafson/jekyll-webmention_io
#  Licence : MIT
#
#  This generator caches sites you mention so they can be mentioned
#

module Jekyll
  class QueueWebmentions < Generator
    safe true
    priority :low

    URI_RE = /(?:https?:)?\/\/[^\s)#"]+/

    def generate(site)
      @site = site

      if @site.config.dig("url").include? 'localhost'
        Jekyll::WebmentionIO.log "msg", "Webmentions lookups are not run on localhost."
        return
      end
      
      if @site.config.dig("webmentions", "pause_lookups")
        Jekyll::WebmentionIO.log "info", "Webmention lookups are currently paused."
        return
      end

      Jekyll::WebmentionIO.log "msg", "Beginning to gather webmentions you’ve made. This may take a while."

      upgrade_outgoing_webmention_cache

      posts = Jekyll::WebmentionIO.gather_documents(@site)

      gather_webmentions(posts)
    end

    private

    def gather_webmentions(posts)
      webmentions = Jekyll::WebmentionIO.read_cached_webmentions "outgoing"

      base_uri = @site.config["url"].chomp("/")

      posts.each do |post|
        uri = "#{base_uri}#{post.url}"
        mentions = get_mentioned_uris(post)
        mtime = webmentions.dig(uri, 'timestamp')
        if mtime and mtime < post.source_file_mtime
          webmentions.delete(uri)
        end
        if webmentions.key? uri
          mentions.each do |mentioned_uri, response|
            unless webmentions[uri].key? mentioned_uri
              webmentions[uri][mentioned_uri] = response
            end
          end
        else
          webmentions[uri] = mentions.merge('timestamp' => post.source_file_mtime)
        end
      end

      Jekyll::WebmentionIO.cache_webmentions "outgoing", webmentions
    end

    def get_mentioned_uris(post)
      uris = {}
      data = (@site.config.dig("webmentions", "link_fields") || ['in_reply_to']).
        map { |k| post.data[k] }
      c = post.content
      block_urls = @site.config.dig("webmentions", "block_urls_in_content")
      if block_urls
        c = c.gsub(/(?:https?:)?\/\/(?:#{block_urls.map { |x| Regexp.quote(x) }.join('|')})/, '')
      end
      data << c

      data.each do |d|
        next unless d
        d.to_s.scan(URI_RE) do |match|
          unless uris.key? match
            uris[match] = false
          end
        end
      end
      return uris
    end

    def upgrade_outgoing_webmention_cache
      old_sent_file = "#{Jekyll::WebmentionIO.cache_folder}/#{Jekyll::WebmentionIO.file_prefix}sent.yml"
      old_outgoing_file = "#{Jekyll::WebmentionIO.cache_folder}/#{Jekyll::WebmentionIO.file_prefix}queued.yml"
      unless File.exist? old_sent_file
        return
      end
      sent_webmentions = open(old_sent_file) { |f| YAML.load(f) }
      outgoing_webmentions = open(old_outgoing_file) { |f| YAML.load(f) }
      merged = {}
      outgoing_webmentions.each do |source_url, webmentions|
        collection = {'timestamp' => webmentions.delete('timestamp')}
        webmentions.each do |target_url, target_response|
          collection[target_url] = if sent_webmentions.dig(source_url, target_url)
                                     target_response || ""
                                   else
                                     false
                                   end
        end
        merged[source_url] = collection
      end
      Jekyll::WebmentionIO.cache_webmentions "outgoing", merged
      File.delete old_sent_file, old_outgoing_file
      Jekyll::WebmentionIO.log "msg", "Upgraded your sent webmentions cache."
    end
  end
end
