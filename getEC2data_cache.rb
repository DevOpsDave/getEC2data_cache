#!/usr/bin/env ruby 

require 'rubygems'
require 'aws-sdk'
require 'httparty'
require 'yaml'
require 'fileutils'
require 'facter'

# Get all the data from the metadata service.
module AWSdata

  class MetaSrvc
    # See /opt/aws/bin/ec2-metadata on an ec2 instance
    @@supported_metadata = %w(
        ami-id ami-launch-index ami-manifest-path block-device-mapping
        instance-id instance-type local-hostname local-ipv4
        kernel-id placement public-keys reservation-id
        security-groups availability-zone region
    )

    # Some of the metadata properties do not keep there data directly under the base_uri.  It might be deeper.
    @@deep_property_path = {
        'availability-zone' => 'placement/availability-zone/',
        'region'            => 'placement/availability-zone/'
    }

    # Post lookup value modification.
    @@post_value_mod = {
        'region' =>  lambda { |arg| "#{arg}".gsub(/(^.*-\d+)([a-z])/,'\1') }
    }

    def self.get(property)
      include HTTParty
      base_uri = 'http://169.254.169.254/latest/meta-data'

      property_string = property.to_s
      property_components = property_string.split '/'

      # Make sure the property is supported.
      raise "Unsupported property #{property_string}" unless @@supported_metadata.include? property_components.first

      # Check to see if this property's data is deeper than the base_uri.  Modify property_string accordingly.
      property_string = @@deep_property_path[property] unless @@deep_property_path[property].nil?

      httparty_response = HTTParty.get "#{base_uri}/#{property_string}/", :timeout => 1
      raise "Error retrieving #{property_string} metadata: HTTP Status #{httparty_response.response.code}" unless httparty_response.response.code == "200"

      unless @@post_value_mod[property]
        return httparty_response.body
      else
        curated_response = @@post_value_mod[property].call(httparty_response.body)
        return curated_response
      end
    end

    def self.get_hash(property)
      value = self.get(property)
      { :key => property, :value => value }
    end

    def self.get_all()
      @@supported_metadata.collect { |k| self.get(k) }
    end

    def self.get_all_hash()
      @@supported_metadata.collect { |k| self.get_hash(k) }
    end

  end

  class EC2Tags
    # EC2 tag stuff.
    @@region = AWSdata::MetaSrvc.get('region')
    @@instance_id = AWSdata::MetaSrvc.get('instance-id')
    AWS.config({ :ec2_endpoint => "ec2.#{@@region}.amazonaws.com",
                 :cf_endpoint => "cf.#{@@region}.amazonaws.com" })
    @@ec2 = AWS::EC2.new

    def self.tags_hash()
      tag_list = @@ec2.client.describe_instances(:instance_ids => [@@instance_id])[:reservation_index][@@instance_id][:instances_set][0][:tag_set]
      tag_list
    end

    def self.tag_hash(tag_name)
      tag_list = self.tags_hash

      tag_value = nil
      begin
        tag_value = tag_list.select { |x| x[:key] == tag_name }[0][:value]
      rescue NoMethodError
      end

      unless tag_value.nil?
        return { :key => tag_name, :value => tag_value }
      end
    end

    def self.tag(tag_name)
      tag_hash = self.tag_hash(tag_name)
      return tag_hash[:value]
    end
  end

  class CloudFormation
    # Cloud formation stuff.
    @@cf = AWS::CloudFormation.new
    @@cf_stack_name = AWSdata::EC2Tags.tag('aws:cloudformation:stack-name')
    @@cf_stack = @@cf.stacks[@@cf_stack_name]
    @@cf_stack_params = @@cf_stack.parameters.collect { |k,v| { :key => k, :value => v } }

    def self.stack_params_hash()
      return @@cf_stack_params
    end
  end

end

# Does a lookup agains AWS and creates the cache_file.
def aws_query(time_now, cache_file_path)

  # Get the ec2 tags.
  # Trying to phase out the ec2_tag_ prefixed facters.  Want to just use the aws_ prefixed ones.  Less noise.
  tags = {}
  AWSdata::EC2Tags.tags_hash.map { |entry|
    entry[:key].gsub!(/:|-/,'_')
    tags["ec2_tag_#{entry[:key]}"] = entry[:value]
    tags["ec2_#{entry[:key]}"] = entry[:value]
  }

  # metadata.
  AWSdata::MetaSrvc.get_all_hash.map { |entry|
    entry[:key].gsub!(/:|-/,'_')
    tags["ec2_tag_#{entry[:key]}"] = entry[:value]
    tags["meta_#{entry[:key]}"] = entry[:value]
  }

  # CF params.
  AWSdata::CloudFormation.stack_params_hash.map { |entry|
    entry[:key].gsub!(/:|-/,'_')
    tags["cf_#{entry[:key]}"] = entry[:value]
  }

  # read_tags_dot_txt
  file = '/etc/facter/facts.d/tags.txt'
  tags_dot_txt = open(file).readlines.each { |line| line.chop! }
  tags_dot_txt.each { |tag|
    (key, val) = tag.split(/=/)
    tags[key] = val
  }

  # put the time stamp in.
  tags['cache_file_modification'] = time_now

  # Write new values to cache.
  FileUtils.mkdir_p(File.split(cache_file_path)[0])
  file_obj = File.open(cache_file_path, "w+")
  YAML::dump(tags, file_obj)
  file_obj.close

  # Return new data.
  tags
end

# C.R.E.A.M
# Wu-Tang are the evangelists of caching.
cache_file = File.basename(__FILE__)+ ".yaml"  # Basename of the cache file.
cache_dir = "/etc/facter/cache.d"              # Location of the caching directory.
cache_file_path = "#{cache_dir}/#{cache_file}" # Final resting place of the cache file.
cache_data_ttl = 120                           # in seconds.
time_now = Time.now.utc.to_i                   # in seconds since epoch.
return_data = {}                               # data that will ultimately become facters.

# load the file.
# If the file is not present or has no data, rescue the exception and make cache_data false.
begin
  cache_data = YAML::load_file(cache_file_path)
rescue Errno::ENOENT
  cache_data = false
end

if cache_data
  # if cache_data is not false then it has data to work with.
  # Check the value of cache_data['cache_file_modification'] and see if
  # it has been too long since last mod.
  if (time_now - cache_data['cache_file_modification'] > cache_data_ttl)
    # if yes then do a look up against AWS.
    return_data = aws_query(time_now, cache_file_path)
  else
    # If cache_file is not too old, then use the data you have already
    # gotten.
    return_data = cache_data
  end
else
  # If it turns out that cache_data is false.  Query AWS and create the
  # cache_file.
  return_data = aws_query(time_now, cache_file_path)
end

# Now create the facters.
return_data.each { |tag, value|
  Facter.add("#{tag}") do
    setcode do
      value
    end
  end
}
