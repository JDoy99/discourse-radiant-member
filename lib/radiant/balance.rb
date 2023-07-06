# frozen_string_literal: true
module Radiant
  # URIs for different chains
  @radiant_uri_arbitrum = "https://api.thegraph.com/subgraphs/name/radiantcapitaldevelopment/radiantcapital"
  @radiant_uri_bsc = "https://api.thegraph.com/subgraphs/name/radiantcapitaldevelopment/radiant-bsc"

  def self.get_siwe_address_by_username(username)
    user = User.find_by_username(username)
    return nil unless user
    get_siwe_address_by_user(user)
  end

  def self.get_siwe_address_by_user(user)
    siwe = user.associated_accounts.filter { |a| a[:name] == "siwe" }.first
    return nil unless siwe
    address = siwe[:description].downcase
    puts "Got #{address} for #{user.username}"
    address
  end

  def self.price_of_rdnt_token
    name = "radiant_dollar_value"
    Discourse
      .cache
      .fetch(name, expires_in: SiteSetting.radiant_dollar_cache_minutes.minutes) do
        begin
          result =
            Excon.get(
              "https://api.coingecko.com/api/v3/simple/price?ids=radiant-capital&vs_currencies=usd&include_last_updated_at=true&precision=3",
              connect_timeout: 3,
            )
          parsed = JSON.parse(result.body)
          price = parsed["radiant-capital"]["usd"]
        rescue => e
          puts "problem getting dollar amount"
        end
        price
      end
  end

  def self.get_rdnt_amount_by_username(username)
    user = User.find_by_username(username)
    return nil unless user
    get_rdnt_amount(user)
  end

  def self.get_rdnt_amount(user)
    puts "getting amount for #{user.username}"

    # Get amounts from both chains with the appropriate multipliers
    rdnt_amount_arbitrum = get_rdnt_amount_from_chain(user, @radiant_uri_arbitrum, 0.8)
    rdnt_amount_bsc = get_rdnt_amount_from_chain(user, @radiant_uri_bsc, 0.5)

    # Log the amounts fetched from each chain
    puts "rdnt_amount_arbitrum: #{rdnt_amount_arbitrum}"
    puts "rdnt_amount_bsc: #{rdnt_amount_bsc}"

    # Sum amounts from both chains
    total_rdnt_amount = rdnt_amount_arbitrum + rdnt_amount_bsc

    # Update groups
    SiteSetting
      .radiant_group_values
      .split("|")
      .each do |g|
        group_name, required_amount = g.split(":")
        group = Group.find_by_name(group_name)
        next unless group
        puts "Processing group #{group.name}"
        if total_rdnt_amount > required_amount.to_i
          puts "adding #{user.username} to #{group.name}"
          group.add(user)
        else
          puts "removing #{user.username} from #{group.name}"
          group.remove(user)
        end
      end
      # Log the final total RDNT amount
      puts "now returning #{total_rdnt_amount} for #{user.username}"
      total_rdnt_amount.to_d.round(2, :truncate).to_f
  end

  # New method for fetching RDNT amount from a specific chain
  def self.get_rdnt_amount_from_chain(user, radiant_uri, multiplier)
    rdnt_amount = 0
    Discourse.cache.fetch("radiant_user-#{user.id}", expires_in: SiteSetting.radiant_user_cache_minutes.minutes) do
      begin
        address = get_siwe_address_by_user(user)
        uri = URI(radiant_uri)
        req = Net::HTTP::Post.new(uri)
        req.content_type = "application/json"
        req.body = {
          query: 'query Lock($address: String!) { lockeds(id: $address, where: {user_: {id: $address}}, orderBy: timestamp, orderDirection: desc, first: 1) { lockedBalance timestamp } lpTokenPrice(id: "1") { price } }',
          variables: {
            address: address
          }
        }.to_json
  
        req_options = { use_ssl: uri.scheme == "https" }
        res = Net::HTTP.start(uri.hostname, uri.port, req_options) { |http| http.request(req) }
        parsed_body = JSON.parse(res.body)
  
        if parsed_body["data"]["lockeds"].any?
          locked_balance = parsed_body["data"]["lockeds"][0]["lockedBalance"].to_i
          lp_token_price = parsed_body["data"]["lpTokenPrice"]["price"].to_i
  
          number_of_digits = lp_token_price.digits.count
          price_divisor = number_of_digits > 9 ? 1e9 : 1e8
          lp_token_price_in_usd = lp_token_price / price_divisor
  
          locked_balance_formatted = locked_balance / 1e18
          locked_balance_in_usd = locked_balance_formatted * lp_token_price_in_usd
  
          rdnt_amount = (locked_balance_in_usd * multiplier) / price_of_rdnt_token
        else
          puts "No locked balances found for #{user.username} on #{radiant_uri}"
        end
      rescue StandardError => e
        puts "Something went wrong getting RDNT amount #{e}"
        0
      end
    end
    rdnt_amount
  end
end

