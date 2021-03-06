#!/usr/bin/env ruby
require "pathname"
require "rubygems"

MAX_API_TWEETS = 3200
MAX_TWEETS_PER_PAGE = 200.0
MAX_TWEETS_PER_REQUEST = 100
MAX_LIKES_PER_PAGE = 100.0

# Keep specific tweet IDs (comma seperated list)
KEEP_THESE = [111111111111111111,222222222222222222]

require "dotenv"
Dotenv.load

require "optimist"
@options = Optimist.options do
  opt :force, "Actually delete/unlike/unretweet tweets", type: :boolean, default: false
  opt :user, "The Twitter username to purge", type: :string, default: ENV["TWITTER_USER"]
  opt :archive, "Twitter archive tweet.js file", type: :string
  opt :days, "Keep tweets/likes under this many days old", default: 180
  opt :olds, "Keep tweets/likes more than this many days old", default: 9999
  opt :rts, "Keep tweet with this many retweets", default: 2
  opt :favs, "Keep tweets with this many likes", default: 2
end

Optimist.die :user, "must be set" if @options[:user].to_s.empty?
if @options[:csv_given] && !File.exist?(@options[:csv])
  Optimist.die :csv, "must be a file that exists"
end

%w[TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET
   TWITTER_ACCESS_TOKEN TWITTER_ACCESS_TOKEN_SECRET].each do |env|
  Optimist.die "#{env} environment variable must be set" unless ENV[env]
end

require "twitter"

@client = Twitter::REST::Client.new do |config|
  config.consumer_key = ENV["TWITTER_CONSUMER_KEY"]
  config.consumer_secret = ENV["TWITTER_CONSUMER_SECRET"]
  config.access_token = ENV["TWITTER_ACCESS_TOKEN"]
  config.access_token_secret = ENV["TWITTER_ACCESS_TOKEN_SECRET"]
end

@oldest_tweet_time_to_keep = Time.now - @options[:days] * 24 * 60 * 60
@newest_tweet_time_to_keep = Time.now - @options[:olds] * 24 * 60 * 60

def too_new?(tweet)
  tweet.created_at > @oldest_tweet_time_to_keep || tweet.created_at < @newest_tweet_time_to_keep
end

def too_new_or_popular?(tweet)
  return true if too_new? tweet

  return false if tweet.retweeted?
  return false if tweet.text.start_with? "RT @"

  if tweet.retweet_count >= @options[:rts]
    puts "Ignoring tweet: too RTd: #{tweet.text}"
    return true
  end

  if tweet.favorite_count >= @options[:favs]
    puts "Ignoring tweet: too liked: #{tweet.text}"
    return true
  end

  if KEEP_THESE.include?(tweet.id) then
    puts "Ignored a tweet that is to be saved forever: #{tweet.text}"
    return true
  end

  false
end

def api_call(method, *args)
  @client.send method, *args
rescue Twitter::Error::TooManyRequests => error
  puts "Rate limit exceeded; waiting until #{error.rate_limit.reset_at}"
  sleep error.rate_limit.reset_in
  retry
end

user = api_call :user, @options[:username]
tweets_to_unlike = []
tweets_to_delete = []

puts "==> Checking likes..."
total_likes = [user.favorites_count, MAX_API_TWEETS].min
oldest_likes_page = (total_likes / MAX_LIKES_PER_PAGE).ceil

oldest_likes_page.downto(1) do |page|
  tweets = api_call :favorites, count: MAX_LIKES_PER_PAGE, page: page
  tweets_to_unlike += tweets.reject(&method(:too_new?))
end

puts "==> Checking timeline..."
total_tweets = [user.statuses_count, MAX_API_TWEETS].min
oldest_tweets_page = (total_tweets / MAX_TWEETS_PER_PAGE).ceil

oldest_tweets_page.downto(1) do |page|
  tweets = api_call :user_timeline, count: MAX_TWEETS_PER_PAGE, page: page
  tweets_to_delete += tweets.reject(&method(:too_new_or_popular?))
end

if @options[:archive_given]
  puts "==> Checking archive JS..."
  archive_tweet_ids = []

  # tweet.js is not valid JSON...
  file_contents = File.read(@options[:archive])
  file_contents.sub! 'window.YTD.tweet.part0 = ', ''

  JSON.parse(file_contents).each do |tweet|
    archive_tweet_ids << tweet["id_str"]
  end

  archive_tweet_ids.each_slice(MAX_TWEETS_PER_REQUEST) do |tweet_ids|
    tweets = api_call :statuses, tweet_ids
    tweets_to_delete += tweets.reject(&method(:too_new_or_popular?))
  end
end

unless @options[:force]
  puts "==> To unlike #{tweets_to_unlike.size} and delete #{tweets_to_delete.size} tweets, re-run the command with --force"
  exit 0
end

puts "==> Unliking #{tweets_to_unlike.size} tweets"
tweets_not_found = []
tweets_to_unlike.each_slice(MAX_TWEETS_PER_REQUEST) do |tweets|
  begin
    api_call :unfavorite, tweets
  rescue Twitter::Error::NotFound
    tweets_not_found += tweets
  end
end

puts "==> Deleting #{tweets_to_delete.size} tweets"
tweets_to_delete.each_slice(MAX_TWEETS_PER_REQUEST) do |tweets|
  begin
    api_call :destroy_status, tweets
  rescue Twitter::Error::NotFound
    tweets_not_found += tweets
  end
end

tweets_not_found.each do |tweet|
  begin
    api_call :destroy_status, tweet
  rescue Twitter::Error::NotFound
    nil
  end
end
