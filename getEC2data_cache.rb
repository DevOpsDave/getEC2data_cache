#!/usr/bin/env ruby

require 'rubygems'
require 'aws-sdk'
require 'httparty'
require 'yaml'
require 'fileutils'
require 'facter'

# Work in progress.
#def get_metadata(ec2_data, items)
#  puts 'hi'
#  items.each { |item|
#    puts item
#    begin
#      resp = HTTParty.get("http://169.254.169.254/latest/meta-data/#{item}").parsed_response
#    rescue
#      next
#    end
#    if resp.split(/\n/).size > 1
#      adjusted_paths = resp.split(/\n/).map { |x| "#{item}"+x }
#      get_metadata(ec2_data, adjusted_paths)
#    elsif resp.split(/\n/).size == 1
#      ec2_data["ec2_metadata_"+item] = resp.split(/\n/)[0]
#    else
#      next
#    end
#  }
#  ec2_data
#end

# Does a lookup agains AWS and creates the cache_file.
def aws_query(time_now, cache_file_path)

  instance_id = HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id').parsed_response
  availability_zone = HTTParty.get('http://169.254.169.254/latest/meta-data/placement/availability-zone/').parsed_response
  region = availability_zone[0..-2]

  AWS.config({:ec2_endpoint => "ec2.#{region}.amazonaws.com"})
  ec2 = AWS::EC2.new

  # Get the tags.
  tags = {}
  tag_list = ec2.client.describe_instances(:instance_ids => [instance_id])[:reservation_index][instance_id][:instances_set][0][:tag_set]
  tag_list.map { |entry|
    entry[:key].gsub!(/:|-/,'_')
    tags["ec2_tag_#{entry[:key]}"] = entry[:value]
  }

  # TODO
  # Trying to write a recursive function to get metadata.
  # Get the metadata.
  #response = HTTParty.get('http://169.254.169.254/latest/meta-data/').parsed_response
  #tags = get_metadata(tags, response.split(/\n/))

  # Get the instance attributes.
  meta_list = %w(instanceType kernel disableApiTermination instanceInitiatedShutdownBehavior)
  meta_list.each do |item|
    resp = ec2.client.describe_instance_attribute(:instance_id => instance_id, :attribute => item)
    value = resp.data[item.gsub(/([A-Z])/, '_\1').downcase.to_sym][:value]
    tags["ec2_attr_"+item] = value
  end

  # read_tags_dot_txt
  file = '/etc/facter/facts.d/tags.txt'
  tags_dot_txt = open(file).readlines.each { |line| line.chop! }
  tags_dot_txt.each { |tag|
    (key, val) = tag.split(/=/)
    tags[key] = val
  }

  # Grab any overtags.  All overtag keys (AT this point in the execution) begin must match this regex.
  # /^ec2_tag_bv_.*_overtags$/.
  # All overtags will be prefaced with the parent tag string + ":" + key name.
  overtags = {}
  tags.each_key do |key|
    if key =~ /^ec2_tag_bv_.*_overtags$/
      tags[key].split(/\|/).each { |item|
        itemkey = item.split(/\:/)[0]
        itemval = item.split(/\:/)[1] ? item.split(/\:/)[1] : 'valueless_tag'
        overtags[key + "_" + itemkey] = itemval
      }
    end
  end
  tags.merge!(overtags)


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
