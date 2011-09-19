# -*- coding: utf-8 -*-

require 'bundler/setup'
require 'json'
require 'twitter'
require 'userstream'

class RPS

  HAND = [ :rock, :scissors, :paper ]

  HAND_TO_STRING = {
    :rock => 'グー',
    :paper => 'パー',
    :scissors => 'チョキ',
  }

  JUDGE = {
    :rock => { :scissors => :rock, :paper => :paper },
    :paper => { :rock => :paper, :scissors => :scissors },
    :scissors => { :paper => :scissors, :rock => :rock },
  }

  MAX_AGE = 1 * 60 * 60

  def initialize
    @battles = (Marshal.load(open('battles.bin').read) rescue [])
    @on_judge = nil
  end

  def on_judge(&block)
    @on_judge = block
  end

  def start(member)
    return false unless member.size >= 2
    @battles.push(
      :member => member,
      :hands => {},
      :expires => Time.now + MAX_AGE)
    save
    true
  end

  def submit(screen_name, hand)
    battle = joined_battle(screen_name) or return false
    return false if battle[:hands].include?(screen_name)
    battle[:hands][screen_name] = hand
    judge battle
    save
    true
  end

  def hand_to_string(hand)
    HAND_TO_STRING[hand]
  end

  def gc
    now = Time.now
    @battles.delete_if {|battle|
      if d = now > battle[:expires]
        battle[:member] = battle[:hands].keys
        judge battle
      end
      d
    }
    save
  end

  private

  def judge(battle)
    unless battle[:member].size >= 2
      @on_judge.call battle, nil 
      return
    end
    if battle[:hands].size == battle[:member].size
      hands = battle[:hands].values.uniq
      if hands.size == 2
        @on_judge.call battle, JUDGE[hands[0]][hands[1]]
      else
        @on_judge.call battle, nil
      end
      @battles.delete battle
    end
  end

  def save
    open('battles.bin', 'w') do |f|
      f << Marshal.dump(@battles)
    end
    @battles
  end

  def joined_battle(screen_name)
    @battles.find {|battle|
      battle[:member].include?(screen_name) && !battle[:hands].include?(screen_name)
    }
  end

end

rps = RPS.new

rps.on_judge do |battle, winner|
  member = battle[:member]
  hands = battle[:hands]
  if member.size >= 2
    result = "じゃんけんの結果 "
    result << "#{member.map {|m| "@#{m}:#{rps.hand_to_string hands[m]}" }.join(' ')} で "
    if winner
      result << "#{rps.hand_to_string winner} が勝利しました。"
    else
      result << "引き分けでした。"
    end
    Twitter::Client.new.update result
  else
    Twitter::Client.new.update "@#{member[0]} 試合は行われませんでした。"
  end
end

config = JSON.parse(open('config.json').read)

account = config['account']
oauth   = config['oauth']

Twitter.configure do |c|
  c.consumer_key       = oauth['consumer_key']
  c.consumer_secret    = oauth['consumer_secret']
  c.oauth_token        = oauth['oauth_token']
  c.oauth_token_secret = oauth['oauth_token_secret']
end

consumer = OAuth::Consumer.new(
  oauth['consumer_key'],
  oauth['consumer_secret'],
  :site => 'https://userstream.twitter.com/')

access_token = OAuth::AccessToken.new(
  consumer,
  oauth['oauth_token'],
  oauth['oauth_token_secret'])

userstream = Userstream.new(consumer, access_token)
userstream.user do |status|
  rps.gc
  case
  when status.event == 'follow'
    unless Twitter.friendship?(account, status.source.screen_name)
      Twitter.follow status.source.id
    end
  when status.text
    unless Twitter.friendship?(status.user.screen_name, account)
      Twitter.unfollow status.user.id
    end
    member = status.text.scan(/@(\w+)/).map {|m| m[0] }
    next unless member.delete(account)
    member.push status.user.screen_name
    member.uniq!
    rps.start member
  when status.direct_message
    hand = case status.direct_message.text
    when /ぐー|グー/
      :rock
    when /ぱー|パー/
      :paper
    when /ちょき|チョキ/
      :scissors
    else
      nil
    end
    next unless hand
    rps.submit status.direct_message.sender.screen_name, hand
  end
end

