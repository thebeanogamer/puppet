# A pool for persistent <tt>Net::HTTP</tt> connections. Connections are
# stored in the pool indexed by their {Puppet::HTTP::Site Site}.
# Connections are borrowed from the pool, yielded to the caller, and
# released back into the pool. If a connection is expired, it will be
# closed either when a connection to that site is requested, or when
# the pool is closed. The pool can store multiple connections to the
# same site, and will be reused in MRU order.
#
# @api private
#
class Puppet::Network::HTTP::Pool < Puppet::Network::HTTP::BasePool
  attr_reader :factory, :keepalive_timeout

  def initialize(keepalive_timeout)
    @pool = {}
    @factory = Puppet::HTTP::Factory.new
    @keepalive_timeout = keepalive_timeout
  end

  def with_connection(site, verifier, &block)
    reuse = true

    http = borrow(site, verifier)
    begin
      if http.use_ssl? && http.verify_mode != OpenSSL::SSL::VERIFY_PEER
        reuse = false
      end

      yield http
    rescue => detail
      reuse = false
      raise detail
    ensure
      if reuse && http.started?
        release(site, verifier, http)
      else
        close_connection(site, http)
      end
    end
  end

  def close
    @pool.each_pair do |site, entries|
      entries.each do |entry|
        close_connection(site, entry.connection)
      end
    end
    @pool.clear
  end

  # @api private
  def pool
    @pool
  end

  # Safely close a persistent connection.
  # Don't try to close a connection that's already closed.
  #
  # @api private
  def close_connection(site, http)
    return false unless http.started?
    Puppet.debug("Closing connection for #{site}")
    http.finish
    true
  rescue => detail
    Puppet.log_exception(detail, _("Failed to close connection for %{site}: %{detail}") % { site: site, detail: detail })
    nil
  end

  # Borrow and take ownership of a persistent connection. If a new
  # connection is created, it will be started prior to being returned.
  #
  # @api private
  def borrow(site, verifier)
    @pool[site] = active_entries(site)
    index = @pool[site].index do |entry|
      (verifier.nil? && entry.verifier.nil?) ||
        (!verifier.nil? && verifier.reusable?(entry.verifier))
    end
    entry = index ? @pool[site].delete_at(index) : nil
    if entry
      @pool.delete(site) if @pool[site].empty?

      Puppet.debug("Using cached connection for #{site}")
      entry.connection
    else
      http = @factory.create_connection(site)

      start(site, verifier, http)
      setsockopts(http.instance_variable_get(:@socket))
      http
    end
  end

  # Set useful socket option(s) which lack from default settings in Net:HTTP
  #
  # @api private
  def setsockopts(netio)
    return unless netio

    socket = netio.io
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
  end

  # Release a connection back into the pool.
  #
  # @api private
  def release(site, verifier, http)
    expiration = Time.now + @keepalive_timeout
    entry = Puppet::HTTP::PoolEntry.new(http, verifier, expiration)
    Puppet.debug("Caching connection for #{site}")

    entries = @pool[site]
    if entries
      entries.unshift(entry)
    else
      @pool[site] = [entry]
    end
  end

  # Returns an Array of entries whose connections are not expired.
  #
  # @api private
  def active_entries(site)
    now = Time.now

    entries = @pool[site] || []
    entries.select do |entry|
      if entry.expired?(now)
        close_connection(site, entry.connection)
        false
      else
        true
      end
    end
  end
end
