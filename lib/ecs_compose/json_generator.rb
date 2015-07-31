require 'psych'
require 'json'

module EcsCompose
  class ContainerKeyError < KeyError
  end

  # Converts from raw YAML text in docker-compose.yml format to ECS task
  # definition JSON.
  class JsonGenerator

    # Create a new generator, specifying the family name to use, and the
    # raw YAML input.
    def initialize(family, yaml_text, services: nil)
      @family = family
      @yaml = Psych.load(yaml_text)
      @services = services
    end

    # Generate an ECS task definition as a raw Ruby hash.
    def generate
      containers = @yaml.map do |name, fields|
        # Skip this service if we've been given a list to emit, and
        # this service isn't on the list.
        begin
          json = {
            "name" => name,
            "image" => fields.fetch("image"),
            # Default to a tiny guaranteed CPU share.
            "cpu" => fields["cpu_shares"] || 2,
            "memory" => mem_limit_to_mb(fields.fetch("mem_limit")),
            "links" => fields["links"] || [],
            "portMappings" =>
              (fields["ports"] || []).map {|pm| port_mapping(pm) },
            "essential" => true,
            "environment" => environment(fields["environment"] || {}),
            "mountPoints" => [],
            "volumesFrom" => [],
          }
          if fields.has_key?("entrypoint")
            json["entryPoint"] = command_line(fields.fetch("entrypoint"))
          end
          if fields.has_key?("command")
            json["command"] = command_line(fields.fetch("command"))
          end
          json

        rescue KeyError => e
          # This makes it a lot easier to localize errors a bit.
          raise ContainerKeyError.new("#{e.message} processing container \"#{name}\"")
        end
      end

      # Prune our services against a list if requested.
      if @services
        containers.select! {|c| @services.include?(c["name"]) }
      end

      {
        "family" => @family,
        "containerDefinitions" => containers,
        "volumes" => []
      }
    end

    # Generate an ECS task definition as serialized JSON.
    def json
      # We do not want to insert much extra whitespace, because ECS imposes
      # a maximum file-size limit based on bytes.
      JSON.generate(generate())
    end

    protected

    # Parse a Docker-style `mem_limit` and convert to megabytes.
    def mem_limit_to_mb(mem_limit)
      unless mem_limit.downcase =~ /\A(\d+)([bkmg])\z/
        raise "Cannot parse docker memory limit: #{mem_limit}"
      end
      val = $1.to_i
      case $2
      when "b" then (val / (1024.0 * 1024.0)).ceil
      when "k" then (val / 1024.0).ceil
      when "m" then (val * 1.0).ceil
      when "g" then (val * 1024.0).ceil
      else raise "Can't convert #{mem_limit} to megabytes"
      end
    end

    # Parse a Docker-style port mapping and convert to ECS format.
    def port_mapping(port)
      case port.to_s
      when /\A(\d+)\z/
        port = $1.to_i
        { "hostPort" => port, "containerPort" => port }
      when /\A(\d+):(\d+)\z/ 
        { "hostPort" => $1.to_i, "containerPort" => $2.to_i }
      else
        raise "Cannot parse port specification: #{port}"
      end
    end

    # Convert a command-line to an array of individual arguments.
    #
    # TODO: What is the exact format of the docker-compose fields here?
    # Can the user pass an array?  Is there a way to escape spaces?
    def command_line(input)
      input.split(/ /)
    end

    # Convert a docker-compose environment to ECS format.  There are other
    # possible formats for this that we don't support yet.
    def environment(env)
      # We need to force string values to keep ECS happy.
      env.map {|k, v| { "name" => k, "value" => v.to_s } }
    end
  end
end
