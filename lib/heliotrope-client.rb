require 'rubygems'
require 'curb'
require 'uri'
require 'json'
require 'set'
require 'lrucache'

class HeliotropeClient
  class Error < StandardError; end

  MESSAGE_MUTABLE_STATE = Set.new %w(starred unread deleted)
  MESSAGE_IMMUTABLE_STATE = Set.new %w(attachment signed encrypted draft sent)
  MESSAGE_STATE = MESSAGE_MUTABLE_STATE + MESSAGE_IMMUTABLE_STATE

  attr_reader :url
  def initialize url
    @url = url
    @cache = LRUCache.new :max_size => 100
    @curl = Curl::Easy.new
  end

  def search query, num=20, start=0
    v = get_json "search", :q => query, :start => start, :num => num
    v["results"]
  end

  def count query
    get_json("count", :q => query)["count"]
  end

  def thread id; get_json("thread/#{id}")["messageinfos"] end
  def threadinfo id; get_json("thread/#{id}/info") end

  def messageinfos id
    @cache[[:message_info, id]] ||= get_json("message/#{id}", :only_infos => true)
  end

  def message id, mime_type_pref="text/plain"
    @cache[[:message, id, mime_type_pref]] ||= get_json("message/#{id}", :mime_type_pref => mime_type_pref)
  end

  def bulk type, ids, params={}
    fetch_ids = ids

    case type
    when :message_info
      fetch_ids.delete_if {|id| !@cache[[:message_info, id]].nil?}

      unless fetch_ids.empty?
        result = post_json "bulk/messages", :ids => fetch_ids, :only_infos => true
        # result #=> [{1=><messageinfos>, 2=><messageinfos>...}]
        result["messageinfos"].each do |messageinfos|
          @cache[[:message_info, messageinfos["message_id"].to_i]] ||= messageinfos
        end
      end

      ids.map {|id| messageinfos(id)}

    when :message
      params[:mime_type_pref] ||= "text/plain"
      fetch_ids.delete_if {|id| !@cache[[:message, id, params[:mime_type_pref]]].nil?}

      unless fetch_ids.empty?
        result = post_json "bulk/messages", :ids => fetch_ids, :only_infos => false
        # result #=> [{1=><messageinfos>, 2=><messageinfos>...}]
        result["messages"].each do |messageinfos|
          @cache[[:message, messageinfos["message_id"].to_i, params[:mime_type_pref]]] ||= messageinfos
        end
      end

      ids.map {|id| message(id, params[:mime_type_pref])}

    when :thread_info
      post_json("bulk/threadinfos", :ids => ids)["threads"].map { |thread| thread["messageinfos"]}

    when :thread
      post_json("bulk/threads", :ids => ids)["threads"]

    end

  end

  def send_message message, opts={}
    opts[:labels] ||= []
    opts[:state] ||= []
    post_json "message/send", :message => message, :labels => opts[:labels].to_json, :state => opts[:state].to_json
  end

  def add_message message, opts={}
    opts[:labels] ||= []
    opts[:state] ||= []
    post_json "message", :message => message, :labels => opts[:labels].to_json, :state => opts[:state].to_json
  end

  def bounce_message message, opts={}
    opts[:force_recipients] ||= []
    post_json "message/bounce", :message => message, :force_recipients => opts[:force_recipients].to_json
  end

  def message_part message_id, part_id
    ## not a json blob, but a binary region
    @cache[[:message_part, message_id, part_id]] ||= get_raw "/message/#{message_id}/part/#{part_id}"
  end

  def raw_message message_id
    ## not a json blob, but a binary region
    @cache[[:raw_message, message_id]] ||= get_raw "/message/#{message_id}/raw"
  end

  def labels; get_json("labels")["labels"] end
  def info; get_json("info") end
  def size; get_json("size")["size"] end
  def contacts_with_prefix prefix, num=100; get_json("contacts", :prefix => prefix, :num => num)["contacts"] end

  def prune_labels!; post_json("labels/prune")["labels"] end

  def set_labels! thread_id, labels
    post_json "thread/#{thread_id}/labels", :labels => labels.to_json
  end

  def set_state! message_id, state
    post_json "message/#{message_id}/state", :state => state.to_json
  end

  def set_thread_state! thread_id, state
    post_json "thread/#{thread_id}/state", :state => state.to_json
  end

private

  def encode_params params; params.map { |k, v| "#{k}=#{CGI.escape v.to_s}" }.join("&") end

  def get_json path, params={}
    handle_errors do
      response = get_raw(path + ".json", params)
      response.force_encoding Encoding::UTF_8 if in_ruby19_hell?
      JSON.parse response
    end
  end

  def post_json path, params={}
    handle_errors do
      curl = Curl::Easy.http_post URI.join(@url, path + ".json").to_s, encode_params(params)
      if curl.response_code != 200
        raise Error, "Unexpected HTTP response code #{curl.response_code} posting to #{curl.url}"
      end
      response = curl.body_str
      response.force_encoding Encoding::UTF_8 if in_ruby19_hell?
      JSON.parse response
    end
  end

  def get_raw resource, params={}
    @curl.url = URI.join(@url, resource).to_s + (params.empty? ? "" : "?" + encode_params(params))
    @curl.http_get
    if @curl.response_code != 200
      raise Error, "Unexpected HTTP response code #{@curl.response_code} getting #{@curl.url}"
    end
    @curl.body_str
  end

  def handle_errors
    begin
      v = yield
      raise Error, "invalid response: #{v.inspect[0..200]}" unless v.is_a?(Hash)
      case v["response"]
        when "ok"; v
        when "error"; raise Error, v.inspect
        else raise Error, "invalid response: #{v.inspect[0..200]}"
      end
    rescue SystemCallError, Curl::Err::CurlError, Curl::JSON::ParserError, SocketError, IOError => e
      raise Error, "#{e.message} (#{e.class})"
    end
  end

  def in_ruby19_hell?
    @in_ruby19_hell = "".respond_to?(:encoding) if @in_ruby19_hell.nil?
    @in_ruby19_hell
  end
end
