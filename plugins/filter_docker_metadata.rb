#
# Fluentd Docker Metadata Filter Plugin - Enrich Fluentd events with Docker
# metadata
#
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Fluent
  class DockerMetadataFilter < Fluent::Filter
    Fluent::Plugin.register_filter('docker_metadata', self)

    config_param :docker_url, :string,  :default => 'unix:///docker.sock'
    config_param :cache_size, :integer, :default => 100
    config_param :container_id_regexp, :string, :default => '(\w{64})'

    def initialize
      super
    end

    def configure(conf)
      super

      require 'docker'
      require 'json'
      require 'lru_redux'

      Docker.url = @docker_url

      @cache = LruRedux::ThreadSafeCache.new(@cache_size)
      @container_id_regexp_compiled = Regexp.compile(@container_id_regexp)

      @options = ENV["LOGSTASH_OPTS"] ? JSON.parse(ENV["LOGSTASH_OPTS"]) : {}
    end

    def get_record_info(container_id)
      begin
        metadata = Docker::Container.get(container_id).info

        image_split = metadata['Config']['Image'].split(':')
        image = image_split[0]
        image_tag = image_split.length > 1 ? image_split[1] : nil
        logstash_opts = build_logstash_opts metadata["Config"]["Env"]

        record_info = {
          'docker' => {
            'cid' => metadata['id'],
            'name' => metadata['Name'][1..-1],
            'image' => image,
            'source' => 'stdout'
          }
        }
        record_info['docker']['args'] = metadata['Config']['Cmd'].join(' ') if metadata['Config']['Cmd']
        record_info['docker']['image_tag'] = image_tag if image_tag
        record_info["options"] = logstash_opts if logstash_opts

        return record_info
      rescue Docker::Error::NotFoundError
        nil
      end
    end

    def build_logstash_opts(container_env)
      opts_env = container_env.find { |v| v.start_with?('LOGSTASH_OPTS=') }
      opts = opts_env == nil ? {} : JSON.parse(opts_env.split('=').drop(1).join('='))
      @options.each do |k, v|
        opts[k] = v unless opts[k]
      end
      opts.length > 0 ? opts : nil
    end

    def filter_stream(tag, es)
      new_es = es
      container_id = tag.match(@container_id_regexp_compiled)
      if container_id && container_id[0]
        container_id = container_id[0]
        record_info = @cache.getset(container_id){ get_record_info(container_id) }

        if record_info
          new_es = MultiEventStream.new
          es.each {|time, record|
            record.merge!(record_info)
            new_es.add(time, record)
          }
        end
      end

      return new_es
    end
  end

end
