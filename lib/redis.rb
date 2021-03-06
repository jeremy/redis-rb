require 'socket'
require File.join(File.dirname(__FILE__),'better_timeout')
require 'set'

class RedisError < StandardError
end

class Redis
  OK = "+OK".freeze
  ERRCODE = "-".freeze
  NIL = 'nil'.freeze
  CTRLF = "\r\n".freeze

  attr_reader :socket

  def to_s
    "#{host}:#{port}"
  end
  
  def port
    @opts[:port]
  end
  
  def host
    @opts[:host]
  end
  
  def initialize(opts={})
    @opts = {:host => 'localhost', :port => '6379'}.merge(opts)
    connect
  end
  
  # SET key value
  # Time complexity: O(1)
  # Set the string value as value of the key. The string can't be longer 
  # than 1073741824 bytes (1 GB).
  # 
  # Return value: status code reply
  def []=(key, val)
    val = redis_marshal(val)
    timeout_retry(3, 3){
      status_code_reply(perform("SET #{key} #{val.size}\r\n#{val}\r\n"))
    }
  end
  
  # SETNX key value
  # 
  # Time complexity: O(1)
  # SETNX works exactly like SET with the only difference that if the key 
  # already exists no operation is performed. SETNX actually means "SET if Not eXists".
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the key was set 0 if the key was not set
  def set_unless_exists(key, val)
    val = redis_marshal(val)
    timeout_retry(3, 3){
      1 == perform("SETNX #{key} #{val.size}\r\n#{val}\r\n")
    }
  end
  
  # GET key
  # Time complexity: O(1)
  # Get the value of the specified key. If the key does not exist the special value 
  # 'nil' is returned. If the value stored at key is not a string an error is 
  # returned because GET can only handle string values.
  #
  # Return value: bulk reply
  def [](key)
    timeout_retry(3, 3){
      res = perform("GET #{key}\r\n")
      bulk_reply(res)
    }
  end
  
  # INCR key
  # INCRBY key value
  # Time complexity: O(1)
  # Increment the number stored at key by one. If the key does not exist or contains 
  # a value of a wrong type, set the key to the value of "1" (like if the previous 
  # value was zero).
  # 
  # INCRBY works just like INCR but instead to increment by 1 the increment is value.
  # 
  # Return value: integer reply
  def incr(key, increment=nil)
    timeout_retry(3, 3){
      if increment
        perform("INCRBY #{key} #{increment}\r\n").to_i
      else
        perform("INCR #{key}\r\n").to_i
      end
    }
  end

  
  # DECR key
  # 
  # DECRBY key value
  # 
  # Time complexity: O(1) Like INCR/INCRBY but decrementing instead of incrementing.
  def decr(key, increment=nil)
    timeout_retry(3, 3){
      perform(increment ?  "DECRBY #{key} #{increment}\r\n" : "DECR #{key}\r\n").to_i
    }
  end
  
  # RANDOMKEY
  # Time complexity: O(1)
  # Returns a random key from the currently seleted DB.
  # 
  # Return value: single line reply
  def randkey
    timeout_retry(3, 3){
      perform("RANDOMKEY\r\n")
    }
  end

  # RENAME oldkey newkey
  # 
  # Atomically renames the key oldkey to newkey. If the source and destination 
  # name are the same an error is returned. If newkey already exists it is 
  # overwritten.
  #
  # Return value: status code reply
  def rename!(oldkey, newkey)
    timeout_retry(3, 3){
      res = perform("RENAME #{oldkey} #{newkey}\r\n")
      status_code_reply(res)
    }
  end
  
  # RENAMENX oldkey newkey
  # Just like RENAME but fails if the destination key newkey already exists.
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the key was renamed 0 if the target key already exist -1 if the 
  # source key does not exist -3 if source and destination eys are the same
  def rename(oldkey, newkey)
    timeout_retry(3, 3){
      res = perform("RENAMENX #{oldkey} #{newkey}\r\n").to_i
      case res
      when -1
        raise RedisError, "source key: #{oldkey} does not exist"
      when 0
        raise RedisError, "target key: #{oldkey} already exists"
      when -3
        raise RedisError, "source and destination keys are the same"
      when 1
        true
      end
    }
  end
  
  # EXISTS key
  # Time complexity: O(1)
  # Test if the specified key exists. The command returns "0" if the key 
  # exists, otherwise "1" is returned. Note that even keys set with an empty 
  # string as value will return "1".
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the key exists 0 if the key does not exist
  def key?(key)
    timeout_retry(3, 3){
      perform("EXISTS #{key}\r\n").to_i == 1
    }
  end
  
  # DEL key
  # Time complexity: O(1)
  # Remove the specified key. If the key does not exist no operation is 
  # performed. The command always returns success.
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the key was removed 0 if the key does not exist
  def delete(key)
    timeout_retry(3, 3){
      perform("DEL #{key}\r\n").to_i == 1
    }
  end
  
  # KEYS pattern
  # Time complexity: O(n) (with n being the number of keys in the DB)
  # Returns all the keys matching the glob-style pattern as space separated strings. 
  # For example if you have in the database the keys "foo" and "foobar" the command 
  # "KEYS foo*" will return "foo foobar".
  # 
  # Note that while the time complexity for this operation is O(n) the constant times 
  # are pretty low. For example Redis running on an entry level laptop can scan a 1 
  # million keys database in 40 milliseconds. Still it's better to consider this one 
  # of the slow commands that may ruin the DB performance if not used with care.
  # 
  # Return value: bulk reply
  def keys(glob)
    timeout_retry(3, 3){
      if res = bulk_reply(perform("KEYS #{glob}\r\n"))
        res.split(' ')
      else
        []
      end
    }
  end
  
  # TYPE key
  # 
  # Time complexity: O(1) Return the type of the value stored at key in form of 
  # a string. The type can be one of "none", "string", "list", "set". "none" is 
  # returned if the key does not exist.
  # 
  # Return value: single line reply
  def type?(key)
    timeout_retry(3, 3){
      perform("TYPE #{key}\r\n")
    }
  end
  
  # RPUSH key string
  # 
  # Time complexity: O(1)
  # Add the given string to the tail of the list contained at key. If the key 
  # does not exist an empty list is created just before the append operation. 
  # If the key exists but is not a List an error is returned.
  # 
  # Return value: status code reply
  def push_tail(key, string)
    string = redis_marshal(string)
    timeout_retry(3, 3){
      res = perform("RPUSH #{key} #{string.size}\r\n#{string}\r\n")
      status_code_reply(res)
    }
  end
  
  # LPUSH key string
  # Time complexity: O(1)
  # Add the given string to the head of the list contained at key. If the 
  # key does not exist an empty list is created just before the append operation. 
  # If the key exists but is not a List an error is returned.
  # 
  # Return value: status code reply
  def push_head(key, string)
    string = redis_marshal(string)
    timeout_retry(3, 3){
      res = perform("LPUSH #{key} #{string.size}\r\n#{string}\r\n")
      status_code_reply(res)
    }
  end
  
  # LPOP key
  # 
  # Time complexity: O(1)
  # Atomically return and remove the first element of the list. For example if 
  # the list contains the elements "a","b","c" LPOP will return "a" and the 
  # list will become "b","c".
  # 
  # If the key does not exist or the list is already empty the special value 
  # 'nil' is returned.
  # 
  # Return value: bulk reply
  def pop_head(key)
    timeout_retry(3, 3){
      res = perform("LPOP #{key}\r\n")
      bulk_reply(res)
    }
  end
  
  # RPOP key
  #     This command works exactly like LPOP, but the last element instead
  #     of the first element of the list is returned/deleted.
  def pop_tail(key)
    timeout_retry(3, 3){
      res = perform("RPOP #{key}\r\n")
      bulk_reply(res)
    }
  end
  
  # LSET key index value
  # Time complexity: O(N) (with N being the length of the list)
  # Set the list element at index (see LINDEX for information about the index argument) with the new value. Out of range indexes will generate an error. Note that setting the first or last elements of the list is O(1).
  # 
  # Return value: status code reply
  def list_set(key, index, val)
    val = redis_marshal(val)
    timeout_retry(3, 3){
      res = perform("LSET #{key} #{index} #{val.size}\r\n#{val}\r\n")
      status_code_reply(res)
    }
  end
  
  
  # LLEN key
  # Time complexity: O(1)
  # Return the length of the list stored at the specified key. If the key does not 
  # exist zero is returned (the same behaviour as for empty lists). If the value 
  # stored at key is not a list the special value -1 is returned. Note: client 
  # library should raise an exception when -1 is returned instead to pass the 
  # value back to the caller like a normal list length value.
  # 
  # *Return value: integer reply, specifically:
  # 
  # the length of the list as an integer
  # >=
  # 0 if the operation succeeded -2 if the specified key does not hold a list valu
  def list_length(key)
    timeout_retry(3, 3){
      res = perform("LLEN #{key}\r\n").to_i
      case res
      when -2
        raise RedisError, "key: #{key} does not hold a list value"
      else
        res
      end
    }
  end
  
  # LRANGE key start end
  # Time complexity: O(n) (with n being the length of the range)
  # Return the specified elements of the list stored at the specified key. Start 
  # and end are zero-based indexes. 0 is the first element of the list (the list head),
  # 1 the next element and so on.
  # 
  # For example LRANGE foobar 0 2 will return the first three elements of the list.
  # 
  # start and end can also be negative numbers indicating offsets from the end of the list.
  #  For example -1 is the last element of the list, -2 the penultimate element and so on.
  # 
  # Indexes out of range will not produce an error: if start is over the end of the list,
  # or start > end, an empty list is returned. If end is over the end of the list Redis
  # will threat it just like the last element of the list.
  # 
  # Return value: multi bulk reply
  def list_range(key, start, ending)
    timeout_retry(3, 3){
      res = perform("LRANGE #{key} #{start} #{ending}\r\n")
      multi_bulk_reply(res)
    }
  end

  
  # LTRIM key start end
  # Time complexity: O(n) (with n being len of list - len of range)
  # Trim an existing list so that it will contain only the specified range of 
  # elements specified. Start and end are zero-based indexes. 0 is the first 
  # element of the list (the list head), 1 the next element and so on.
  # 
  # For example LTRIM foobar 0 2 will modify the list stored at foobar key so that 
  # only the first three elements of the list will remain.
  # 
  # start and end can also be negative numbers indicating offsets from the end of 
  # the list. For example -1 is the last element of the list, -2 the penultimate 
  # element and so on.
  # 
  # Indexes out of range will not produce an error: if start is over the end of 
  # the list, or start > end, an empty list is left as value. If end over the 
  # end of the list Redis will threat it just like the last element of the list.
  # 
  # Hint: the obvious use of LTRIM is together with LPUSH/RPUSH. For example:
  # 
  # LPUSH mylist <someelement>         LTRIM mylist 0 99
  # The above two commands will push elements in the list taking care that the 
  # list will not grow without limits. This is very useful when using Redis 
  # to store logs for example. It is important to note that when used in this 
  # way LTRIM is an O(1) operation because in the average case just one element 
  # is removed from the tail of the list.
  #
  # Return value: status code reply
  def list_trim(key, start, ending)
    timeout_retry(3, 3){
      res = perform("LTRIM #{key} #{start} #{ending}\r\n")
      status_code_reply(res)
    }
  end
  
  # LINDEX key index
  # Time complexity: O(n) (with n being the length of the list)
  # Return the specified element of the list stored at the specified key. 0 is 
  # the first element, 1 the second and so on. Negative indexes are supported, 
  # for example -1 is the last element, -2 the penultimate and so on.
  # 
  # If the value stored at key is not of list type an error is returned. If 
  # the index is out of range an empty string is returned.
  # 
  # Note that even if the average time complexity is O(n) asking for the first
  # or the last element of the list is O(1).
  # 
  # Return value: bulk reply
  def list_index(key, index)
    timeout_retry(3, 3){
      res = perform("LINDEX #{key} #{index}\r\n")
      bulk_reply(res)
    }
  end
  
  # LREM key count value
  # 
  # Time complexity: O(N) (with N being the length of the list)
  # 
  # Remove the first count occurrences of the value element from the list. 
  # If count is zero all the elements are removed. If count is negative 
  # elements are removed from tail to head, instead to go from head to 
  # tail that is the normal behaviour. So for example LREM with count -2 
  # and hello as value to remove against the list (a,b,c,hello,x,hello,hello) 
  # will lave the list (a,b,c,hello,x). The number of removed elements is 
  # returned as an integer, see below for more information aboht the returned value.
  # Return value
  # 
  # Integer Reply, specifically:
  # 
  # The number of removed elements if the operation succeeded
  # -1 if the specified key does not exist
  # -2 if the specified key does not hold a list value
  def list_rm(key, count, value)
    value = redis_marshal(value)
    res = perform("LREM #{key} #{count} #{value.size}\r\n#{value}\r\n").to_i
    case res
    when -1
      raise RedisError, "key: #{key} does not exist"
    when -2
      raise RedisError, "key: #{key} does not hold a list value"
    else
      res
    end
  end
  
  # SADD key member
  # Time complexity O(1)
  # Add the specified member to the set value stored at key. If member is 
  # already a member of the set no operation is performed. If key does not 
  # exist a new set with the specified member as sole member is crated. If 
  # the key exists but does not hold a set value an error is returned.
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the new element was added 0 if the new element was already a member
  # of the set -2 if the key contains a non set value
  def set_add(key, member)
    member = redis_marshal(member)
    timeout_retry(3, 3){
      res = perform("SADD #{key} #{member.size}\r\n#{member}\r\n").to_i
      case res
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    }
  end
  
  # SREM key member
  # 
  # Time complexity O(1)
  # Remove the specified member from the set value stored at key. If member 
  # was not a member of the set no operation is performed. If key does not 
  # exist or does not hold a set value an error is returned.
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the new element was removed 0 if the new element was not a member 
  # of the set -2 if the key does not hold a set value
  def set_delete(key, member)
    member = redis_marshal(member)
    timeout_retry(3, 3){
      res = perform("SREM #{key} #{member.size}\r\n#{member}\r\n")
      case res
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    }
  end
  
  # SCARD key
  # Time complexity O(1)
  # Return the set cardinality (number of elements). If the key does not 
  # exist 0 is returned, like for empty sets. If the key does not hold a 
  # set value -1 is returned. Client libraries should raise an error when -1 
  # is returned instead to pass the value to the caller.
  # 
  # *Return value: integer reply, specifically:
  # 
  # the cardinality (number of elements) of the set as an integer
  # >=
  # 0 if the operation succeeded -2 if the specified key does not hold a set value
  def set_count(key)
    timeout_retry(3, 3){
      res = perform("SCARD #{key}\r\n").to_i
      case res
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      else
        res
      end
    }
  end
  
  # SISMEMBER key member
  # 
  # Time complexity O(1)
  # Return 1 if member is a member of the set stored at key, otherwise 0 is 
  # returned. On error a negative value is returned. Client libraries should 
  # raise an error when a negative value is returned instead to pass the value 
  # to the caller.
  # 
  # *Return value: integer reply, specifically:
  # 
  # 1 if the element is a member of the set 0 if the element is not a member of
  # the set OR if the key does not exist -2 if the key does not hold a set value
  def set_member?(key, member)
    member = redis_marshal(member)
    timeout_retry(3, 3){
      res = perform("SISMEMBER #{key} #{member.size}\r\n#{member}\r\n").to_i
      case res
      when 1
        true
      when 0
        false
      when -2
        raise RedisError, "key: #{key} contains a non set value"
      end
    }
  end
  
  # SINTER key1 key2 ... keyN
  # Time complexity O(N*M) worst case where N is the cardinality of the smallest 
  # set and M the number of sets
  # Return the members of a set resulting from the intersection of all the sets 
  # hold at the specified keys. Like in LRANGE the result is sent to the client 
  # as a multi-bulk reply (see the protocol specification for more information). 
  # If just a single key is specified, then this command produces the same 
  # result as SELEMENTS. Actually SELEMENTS is just syntax sugar for SINTERSECT.
  # 
  # If at least one of the specified keys does not exist or does not hold a set
  # value an error is returned.
  # 
  # Return value: multi bulk reply
  def set_intersect(*keys)
    timeout_retry(3, 3){
      res = perform("SINTER #{keys.join(' ')}\r\n")
      Set.new(multi_bulk_reply(res))
    }
  end
  
  # SINTERSTORE dstkey key1 key2 ... keyN
  # 
  # Time complexity O(N*M) worst case where N is the cardinality of the smallest set and M the number of sets
  # This commnad works exactly like SINTER but instead of being returned the resulting set is sotred as dstkey.
  # 
  # Return value: status code reply
  def set_inter_store(destkey, *keys)
    timeout_retry(3, 3){
      res = perform("SINTERSTORE #{destkey} #{keys.join(' ')}\r\n")
      status_code_reply(res)
    }
  end
  
  # SMEMBERS key
  # 
  # Time complexity O(N)
  # Return all the members (elements) of the set value stored at key. 
  # This is just syntax glue for SINTERSECT.
  def set_members(key)
    timeout_retry(3, 3){
      res = perform("SMEMBERS #{key}\r\n")
      Set.new(multi_bulk_reply(res))
    }
  end
  
  
  # SORT key [BY pattern] [GET|DEL|INCR|DECR pattern] [ASC|DESC] [LIMIT start count]
  # Sort the elements contained in the List or Set value at key. By default sorting is 
  # numeric with elements being compared as double precision floating point numbers. 
  # This is the simplest form of SORT.
  # SORT mylist
  # 
  # Assuming mylist contains a list of numbers, the return value will be the list of 
  # numbers ordered from the smallest to the bigger number. In order to get the sorting 
  # in reverse order use DESC:
  # SORT mylist DESC
  #
  # ASC is also supported but it's the default so you don't really need it. If you 
  # want to sort lexicographically use ALPHA. Note that Redis is utf-8 aware 
  # assuming you set the right value for the LC_COLLATE environment variable.
  #
  # Sort is able to limit the number of results using the LIMIT option:
  # SORT mylist LIMIT 0 10
  # In the above example SORT will return only 10 elements, starting from the first one 
  # (star is zero-based). Almost all the sort options can be mixed together. For example:
  # SORT mylist LIMIT 0 10 ALPHA DESC
  # Will sort mylist lexicographically, in descending order, returning only the first 
  # 10 elements.
  # Sometimes you want to sort elements using external keys as weights to compare 
  # instead to compare the actual List or Set elements. For example the list mylist 
  # may contain the elements 1, 2, 3, 4, that are just the unique IDs of objects 
  # stored at object_1, object_2, object_3 and object_4, while the keys weight_1, 
  # weight_2, weight_3 and weight_4 can contain weights we want to use to sort the 
  # list of objects identifiers. We can use the following command:
  # SORT mylist BY weight_*
  # the BY option takes a pattern (weight_* in our example) that is used in order to 
  # generate the key names of the weights used for sorting. Weight key names are obtained 
  # substituting the first occurrence of * with the actual value of the elements on the 
  # list (1,2,3,4 in our example).
  # Still our previous example will return just the sorted IDs. Often it is needed to 
  # get the actual objects sorted (object_1, ..., object_4 in the example). We can do 
  # it with the following command:
  # SORT mylist BY weight_* GET object_*
  # Note that GET can be used multiple times in order to get more key for every 
  # element of the original List or Set sorted.
  
  # redis.sort 'index', :by => 'weight_*',
  #                     :order => 'DESC ALPHA',
  #                     :limit => [0,10],
  #                     :get => 'obj_*'
  def sort(key, opts={})
    cmd = "SORT #{key}"
    cmd << " BY #{opts[:by]}" if opts[:by]
    cmd << " GET #{opts[:get]}" if opts[:get]
    cmd << " INCR #{opts[:incr]}" if opts[:incr]
    cmd << " DEL #{opts[:del]}" if opts[:del]
    cmd << " DECR #{opts[:decr]}" if opts[:decr]
    cmd << " #{opts[:order]}" if opts[:order]
    cmd << " LIMIT #{opts[:limit].join(' ')}" if opts[:limit]
    cmd << "\r\n"
    multi_bulk_reply(perform(cmd))
  end
  
  # ADMIN functions for redis
  
  # SELECT index
  # 
  # Select the DB with having the specified zero-based numeric index. 
  # For default every new client connection is automatically selected to DB 0.
  # Return value: status code reply
  def select_db(index)
    timeout_retry(3, 3){
      status_code_reply(perform("SELECT #{index}\r\n"))
    }
  end

  # MOVE key dbindex
  # 
  # Move the specified key from the currently selected DB to the specified 
  # destination DB. Note that this command returns 1 only if the key was 
  # successfully moved, and 0 if the target key was already there or if 
  # the source key was not found at all, so it is possible to use MOVE 
  # as a locking primitive.
  #
  # *Return value: integer reply, specifically:
  # 
  # 1 if the key was moved 0 if the key was not moved because already 
  # present on the target DB or was not found in the current DB. -3 
  # if the destination DB is the same as the source DB -4 if the database 
  # index if out of range
  def move(key, index)
    timeout_retry(3, 3){
      res = perform("MOVE #{index}\r\n").to_i
      case res
      when 1
        true
      when 0
        false
      when -3
        raise RedisError, "destination db same as source db"
      when -4
        raise RedisError, "db index if out of range"
      end
    }
  end
  
  # SAVE
  # 
  # Save the DB on disk. The server hangs while the saving is not completed, 
  # no connection is served in the meanwhile. An OK code is returned when 
  # the DB was fully stored in disk.
  # Return value: status code reply
  def save
    timeout_retry(3, 3){
      status_code_reply(perform("SAVE\r\n"))
    }
  end
  
  # BGSAVE
  # 
  # Save the DB in background. The OK code is immediately returned. Redis 
  # forks, the parent continues to server the clients, the child saves 
  # the DB on disk then exit. A client my be able to check if the operation 
  # succeeded using the LASTSAVE command.
  # Return value: status code reply
  def bgsave
    timeout_retry(3, 3){
      status_code_reply(perform("BGSAVE\r\n"))
    }
  end
  
  # LASTSAVE
  # 
  # Return the UNIX TIME of the last DB save executed with success. A client 
  # may check if a BGSAVE command succeeded reading the LASTSAVE value, then 
  # issuing a BGSAVE command and checking at regular intervals every N seconds 
  # if LASTSAVE changed.
  #
  # Return value: integer reply (UNIX timestamp)
  def lastsave
    timeout_retry(3, 3){
      perform("LASTSAVE\r\n").to_i
    }
  end
  
  def quit
    timeout_retry(3, 3){
      perform("QUIT\r\n")
    }
    close
  end

  
  def info
    info = {}
  
    x = timeout_retry(3, 3){
      size = perform("INFO\r\n").to_i.abs
      @socket.read(size).split("\r\n")
    }
  
    x.each do |kv|
      k,v = kv.split(':')[0], kv.split(':')[1]
      info[k.to_sym] = v
    end
  
    info
  end
  
  def flush_db
    timeout_retry(3, 3){
      perform("FLUSHDB\r\n")
    }
  end
  
  
  def last_save
    timeout_retry(3, 3){
      perform("LASTSAVE\r\n").to_i
    }
  end
  
  def connect
    @socket = TCPSocket.new(@opts[:host], @opts[:port])
    @socket.sync = true
    @socket
  end

  def close
    @socket.close if @socket && !@socket.closed?
  end

  def reconnect
    close
    connect
  end

  private

  def perform(command)
    puts "> #{command}" if ENV['DEBUG']
    @socket.write(command)
    res = read_proto
    puts "< #{res}" if ENV['DEBUG']
    res
  end

  def fetch(len)
    len = [0, len.to_i].max
    res = @socket.read(len + 2)
    res = res.chop if res
    puts "| #{res}" if ENV['DEBUG']
    res
  end

  def read_proto
    if res = @socket.gets
      res.chop
    end
  end
  
  
  def status_code_reply(res)
    if res.index(ERRCODE) == 0
      raise(RedisError, res)
    else
      true
    end
  end
  
  def bulk_reply(res)
    if res.index(ERRCODE) == 0
      raise RedisError, fetch(res)
    elsif res != NIL
      redis_unmarshal(fetch(res))
    else
      nil
    end
  end
  
  
  def multi_bulk_reply(res)
    if res.index(ERRCODE) == 0
      raise RedisError, fetch(res)
    elsif res == NIL
      nil  
    else
      list = []
      Integer(res).times do
        list << redis_unmarshal(fetch(Integer(read_proto)))
      end
      list
    end
  end

  def timeout_retry(time, retries, &block)
    timeout(time, &block)
  rescue TimeoutError
    retries -= 1
    retries < 0 ? raise : retry
  end

  def redis_unmarshal(obj)
    if obj && obj[0] == 4
      Marshal.load(obj)
    else
      obj
    end
  end
  
  def redis_marshal(obj)
    case obj
    when String
      obj
    when Integer
      obj.to_s
    else
      Marshal.dump(obj)
    end
  end
end
