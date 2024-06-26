-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local app = require("core.app")
local link = require("core.link")
local config = require("core.config")
local packet = require("core.packet")
local timer = require("core.timer")
local counter = require("core.counter")
local basic_apps = require("apps.basic.basic_apps")
local ffi = require("ffi")
local C = ffi.C
local floor, min = math.floor, math.min

--- # `Rate limiter` app: enforce a byte-per-second limit

-- uses http://en.wikipedia.org/wiki/Token_bucket algorithm
-- single bucket, drop non-conformant packets

-- bucket capacity and content - bytes
-- rate - bytes per second

RateLimiter = {
   config = {
      rate             = {required=true},
      bucket_capacity  = {required=true},
      initial_capacity = {required=false}
   }
}

-- Source produces synthetic packets of such size
local PACKET_SIZE = 60

function RateLimiter:new (conf)
   conf.initial_capacity = conf.initial_capacity or conf.bucket_capacity
   local o =
   {
      rate = conf.rate,
      bucket_capacity = conf.bucket_capacity,
      bucket_content = conf.initial_capacity,
      shm = { txdrop = {counter} }
    }
   return setmetatable(o, {__index=RateLimiter})
end

function RateLimiter:reset(rate, bucket_capacity, initial_capacity)
   assert(rate)
   assert(bucket_capacity)
   self.rate = rate
   self.bucket_capacity = bucket_capacity
   self.bucket_content = initial_capacity or bucket_capacity
end

-- return statistics snapshot
function RateLimiter:get_stat_snapshot ()
   return
   {
      rx = link.stats(self.input.input).txpackets,
      tx = link.stats(self.output.output).txpackets,
      time = tonumber(C.get_time_ns()),
   }
end

function RateLimiter:push ()
   local i = assert(self.input.input, "input port not found")
   local o = assert(self.output.output, "output port not found")

   do
      local cur_now = tonumber(app.now())
      local last_time = self.last_time or cur_now
      self.bucket_content = min(
            self.bucket_content + self.rate * (cur_now - last_time),
            self.bucket_capacity
         )
      self.last_time = cur_now
   end


   while not link.empty(i) do
      local p = link.receive(i)
      local length = p.length

      if length <= self.bucket_content then
         self.bucket_content = self.bucket_content - length
         link.transmit(o, p)
      else
         -- discard packet
         counter.add(self.shm.txdrop)
         packet.free(p)
      end
   end
end

local function compute_effective_rate (rl, rate, snapshot)
   local elapsed_time =
      (tonumber(C.get_time_ns()) - snapshot.time) / 1e9
   local tx = link.stats(rl.output.output).txpackets - snapshot.tx
   return floor(tx * PACKET_SIZE / elapsed_time)
end

function selftest ()
   print("Rate limiter selftest")
   
   local c = config.new()
   config.app(c, "source", basic_apps.Source)
--   app.apps.source = app.new(basic_apps.Source:new())

   local ok = true
   local rate_non_busy_loop = 200000
   local effective_rate_non_busy_loop
   -- bytes
   local bucket_size = rate_non_busy_loop / 4
   -- should be big enough to process packets generated by Source:pull()
   -- during 100 ms - internal RateLimiter timer resolution
   -- small value may limit effective rate

   local arg = { rate = rate_non_busy_loop,
                 bucket_capacity = rate_non_busy_loop / 4 }
   config.app(c, "ratelimiter", RateLimiter, arg)
   config.app(c, "sink", basic_apps.Sink)

   -- Create a pipeline:
   -- Source --> RateLimiter --> Sink
   config.link(c, "source.output -> ratelimiter.input")
   config.link(c, "ratelimiter.output -> sink.input")
   app.configure(c)
   
   -- XXX do this in new () ?
   local rl = app.app_table.ratelimiter

   local seconds_to_run = 5
   -- print packets statistics every second
   timer.activate(timer.new(
         "report",
         function ()
            app.report()
            seconds_to_run = seconds_to_run - 1
         end,
         1e9, -- every second
         'repeating'
      ))

   -- bytes per second
   do
      print("\ntest effective rate, non-busy loop")

      local snapshot = rl:get_stat_snapshot()

      -- push some packets through it
      app.main{duration=seconds_to_run}
      -- print final report
      app.report()

      effective_rate_non_busy_loop = compute_effective_rate(
            rl,
            rate_non_busy_loop,
            snapshot
         )
      print("configured rate is", rate_non_busy_loop, "bytes per second")
      print(
            "effective rate is",
            effective_rate_non_busy_loop,
            "bytes per second"
         )
      local accepted_min = floor(rate_non_busy_loop * 0.9)
      local accepted_max = floor(rate_non_busy_loop * 1.1)

      if effective_rate_non_busy_loop < accepted_min or
         effective_rate_non_busy_loop > accepted_max then
         print("test failed")
         ok = false
      end
   end

   do
      print("measure throughput on heavy load...")

      -- bytes per second
      local rate_busy_loop = 1200000000
      local effective_rate_busy_loop

      -- bytes
      local bucket_size = rate_busy_loop / 10
      -- should be big enough to process packets generated by Source:pull()
      -- during 100 ms - internal RateLimiter timer resolution
      -- small value may limit effective rate
      -- too big value may produce burst in the beginning

      rl:reset(rate_busy_loop, bucket_size)

      local snapshot = rl:get_stat_snapshot()
      app.main{duration=0.1}
      local elapsed_time =
         (tonumber(C.get_time_ns()) - snapshot.time) / 1e9
      print("elapsed time ", elapsed_time, "seconds")

      local rx = link.stats(rl.input.input).txpackets - snapshot.rx
      print("packets received", rx, floor(rx / elapsed_time / 1e6), "Mpps")

      effective_rate_busy_loop = compute_effective_rate(
            rl,
            rate_busy_loop,
            snapshot
         )
      print("configured rate is", rate_busy_loop, "bytes per second")
      print(
            "effective rate is",
            effective_rate_busy_loop,
            "bytes per second"
         )
      print(
            "throughput is",
            floor(effective_rate_busy_loop / PACKET_SIZE / 1e6),
            "Mpps")

      -- on poor computer effective rate may be too small
      -- so no formal checks
   end

   if not ok then
      print("selftest failed")
      os.exit(1)
   end
   print("selftest passed")
end
