# frozen_string_literal: true

require 'resolv'
require 'ipaddr'

# SSRF protection for feed URLs (spec 15): https only (http when
# GTFS_ALLOW_HTTP=true), no credentials in the URL, and the host must not
# resolve to loopback/private/link-local addresses unless
# GTFS_ALLOW_PRIVATE_HOSTS=true. Returns the resolved IP to connect to, so a
# second DNS answer cannot redirect the connection (DNS rebinding).
module Gtfs::UrlGuard
  class Blocked < StandardError; end

  BLOCKED_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
    192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/32 2001:db8::/32 2002::/16 fc00::/7
    fe80::/10 fec0::/10 ff00::/8
  ].map { |r| IPAddr.new(r) }.freeze
  NAT64 = IPAddr.new('64:ff9b::/96')
  SIX_TO_FOUR = IPAddr.new('2002::/16')

  module_function

  # Returns the address to connect to. Every resolved address must be public
  # (a host with one private answer is rejected); IPv4 is preferred so an
  # IPv6-only first answer does not break containers without IPv6.
  def check!(uri, resolver: Resolv)
    uri = URI.parse(uri.to_s) unless uri.is_a?(URI::Generic)
    allowed = allow_http? ? %w[https http] : %w[https]
    raise Blocked, "scheme #{uri.scheme.inspect} is not allowed" unless allowed.include?(uri.scheme)
    raise Blocked, 'URL must have a host' if uri.host.blank?
    raise Blocked, 'credentials in the URL are not allowed, use the auth settings' if uri.userinfo.present?

    addresses = resolver.getaddresses(uri.host).map(&:to_s).uniq
    raise Blocked, "cannot resolve #{uri.host}" if addresses.empty?

    unless allow_private?
      addresses.each do |address|
        raise Blocked, "#{uri.host} resolves to a private or reserved address" if blocked?(address)
      end
    end
    addresses.find { |a| IPAddr.new(a).ipv4? } || addresses.first
  end

  def blocked?(address)
    candidates(IPAddr.new(address)).any? do |ip|
      ip.private? || ip.loopback? || ip.link_local? ||
        BLOCKED_RANGES.any? { |r| r.family == ip.family && r.include?(ip) }
    end
  rescue IPAddr::InvalidAddressError
    true
  end

  # The address itself plus any IPv4 address embedded in it (IPv4-mapped,
  # NAT64, 6to4), so e.g. ::ffff:127.0.0.1 or 2002:7f00:1:: count as loopback.
  def candidates(ip)
    list = [ip]
    return list unless ip.ipv6?

    list << ip.native if ip.ipv4_mapped? || ip.ipv4_compat?
    list << IPAddr.new(ip.to_i & 0xffff_ffff, Socket::AF_INET) if NAT64.include?(ip)
    list << IPAddr.new((ip.to_i >> 80) & 0xffff_ffff, Socket::AF_INET) if SIX_TO_FOUR.include?(ip)
    list
  end

  def allow_http?
    ENV['GTFS_ALLOW_HTTP'].to_s == 'true'
  end

  def allow_private?
    ENV['GTFS_ALLOW_PRIVATE_HOSTS'].to_s == 'true'
  end
end
