module(..., package.seeall)

local yang = require("lib.yang.yang")
local yang_util = require("lib.yang.util")
local ptree = require("lib.ptree.ptree")
local numa = require("lib.numa")
local pci = require("lib.hardware.pci")
local lib = require("core.lib")
local app_graph = require("core.config")

local probe = require("program.ipfix.lib")

local ipfix_schema = 'snabb-snabbflow-v1'

function setup_ipfix (conf)
   -- yang.print_config_for_schema_by_name(ipfix_schema, conf, io.stdout)
   return setup_workers(conf)
end

function start (confpath)
   local conf = yang.load_configuration(confpath, {schema_name=ipfix_schema})
   return ptree.new_manager{
      setup_fn = setup_ipfix,
      initial_configuration = conf,
      schema_name = ipfix_schema,
   }
end

function run (args)
   local confpath = assert(args[1])
   -- print("Confpath is:", confpath)
   local manager = start(confpath)
   manager:main()
end

local ipfix_default_config = lib.deepcopy(probe.probe_config)
for _, key in ipairs({
      "collector_ip",
      "collector_port",
      "observation_domain",
      "exporter_mac",
      "templates",
      "output_type",
      "output",
      "input_type",
      "input",
      "instance"
}) do
   ipfix_default_config[key] = nil
end

function setup_workers (config)
   local main = config.snabbflow_config
   local interfaces = main.interfaces
   local ipfix = main.ipfix
   local rss = main.rss

   local collector_pools = {}
   for name, p in pairs(ipfix.collector_pools) do
      local collectors = {}
      for entry in p.pool:iterate() do
         table.insert(collectors, {
            ip = yang_util.ipv4_ntop(entry.key.ip),
            port = entry.key.port
         })
      end
      collector_pools[name] = collectors
   end

   local classes = {}
   local function rss_link_name (class, weight)
      if not classes[class] then
         classes[class] = 0
      end
      local instance = classes[class] + 1
      classes[class] = instance
      return class.."_"..instance..(weight > 1 and "_"..weight or '')
   end

   local workers = {}

   local mellanox = {}
   local observation_domain = ipfix.observation_domain_base

   -- Determine NUMA affinity for the input interfaces
   -- local pci_addrs = {}
   -- for device in pairs(interfaces) do
   --    table.insert(pci_addrs, device)
   -- end
   -- local node = numa.choose_numa_node_for_pci_addresses(pci_addrs)
   -- local cpu_pool = {}
   -- Copy cpu_pool ffi array from config into local Lua table
   -- for _, core in ipairs(rss.cpu_pool) do
   --    table.insert(cpu_pool, core)
   -- end
   -- local cpu_pool_size = #cpu_pool
   -- local function cpu_for_node (activate)
   --    if not activate then return nil end
   --    for n, cpu in ipairs(cpu_pool) do
   --       local cpu_node =  numa.cpu_get_numa_node(cpu)
   --       if cpu_node == node then
   --          return table.remove(cpu_pool, n)
   --       end
   --    end
   --    return nil
   -- end
   -- local function log_cpu_choice (pid, cpu, activate)
   --    if cpu_pool_size == 0 or not activate then return end
   --    if cpu then
   --       logger:log(string.format("Binding #%d to CPU %d, "
   --                                   .."NUMA node %d",
   --                                pid, cpu, node))
   --    else
   --       logger:log(string.format("Not binding #%d to any CPU "
   --                                .."(no match found in pool for "
   --                                   .."NUMA node %d)", pid, node))
   --    end
   -- end

   for rssq = 0, rss.hardware_scaling-1 do
      local inputs, outputs = {}, {}
      for device, opt in pairs(interfaces) do
         local device = device
         local input = lib.deepcopy(opt)
         input.rxq = rssq
         inputs[device] = input

         -- The mellanox driver requires a master process that sets up
         -- all queues for the interface. We collect all queues per
         -- device of this type here.
         local device_info = pci.device_info(device)
         if device_info.driver == 'apps.mellanox.connectx' then
            local spec = mellanox[device]
            if not spec then
               spec = { ifName = input.name,
                        ifAlias = input.description,
                        queues = {},
                        recvq_size = input.receive_queue_size }
               mellanox[device] = spec
            end
            table.insert(spec.queues, { id = rssq })
         end
      end

      local embedded_instance = 1
      for name, exporter in pairs(ipfix.exporters) do
         local config = {}
         for key in pairs(ipfix_default_config) do
            config[key] = ipfix[key]
         end
         config.exporter_ip = yang_util.ipv4_ntop(ipfix.exporter_ip)

         config.collector_pool = exporter.collector_pool
         config.templates = exporter.templates

         config.output_type = "tap_routed"
         config.instance = nil
         config.add_packet_metadata = false

         if exporter.use_maps then
            local maps = {}
            for name, map in pairs(ipfix.maps) do
               maps[name] = map.file
            end
            config.maps = maps
         end

         local num_instances = 0
         for _ in pairs(exporter.instances) do
            num_instances = num_instances + 1
         end
         for id, instance in pairs(exporter.instances) do
            -- Create a clone of the configuration for parameters
            -- specific to the instance
            local iconfig = lib.deepcopy(config)
            local rss_link = rss_link_name(exporter.rss_class, instance.weight)
            local od = observation_domain

            -- Select the collector ip and port from the front of the
            -- pool and rotate the pool's elements by one
            local pool = config.collector_pool
            assert(collector_pools[pool] and #collector_pools[pool] > 0,
                   "Undefined or empty collector pool: "..pool)
            collector = table.remove(collector_pools[pool], 1)
            table.insert(collector_pools[pool], collector)
            iconfig.collector_ip = collector.ip
            iconfig.collector_port = collector.port
            iconfig.collector_pool = nil

            iconfig.log_date = ipfix.log_date
            observation_domain = observation_domain + 1
            iconfig.observation_domain = od
            iconfig.output = "ipfixexport"..od
            if exporter.maps_log_dir then
               iconfig.maps_logfile =
                  exporter.maps_log_dir.."/"..od..".log"
            end

            -- Scale the scan protection parameters by the number of
            -- ipfix instances in this RSS class
            local scale_factor = rss.hardware_scaling * num_instances
            iconfig.scan_protection = {
               threshold_rate = ipfix.scan_protection.threshold_rate / scale_factor,
               export_rate = ipfix.scan_protection.export_rate / scale_factor,
            }

            local output
            if instance.embed then
               output = {
                  link_name = rss_link,
                  args = iconfig,
                  instance = embedded_instance
               }
               embedded_instance = embedded_instance + 1
            else
               output = { type = "interlink", link_name = rss_link }
               iconfig.input_type = "interlink"
               iconfig.input = rss_link

               -- local cpu = cpu_for_node(instance.pin_cpu) -- XXX not honored
               workers[rss_link] = probe.configure_graph(iconfig)
            end
            table.insert(outputs, output)
         end
      end
 
      -- XXX ifmib not created for workers (above and below)

      -- local cpu = cpu_for_node(rss.pin_cpu) -- XXX not honored
      local rss_config = {
         default_class = rss.software_scaling.default_class,
         classes = {},
         remove_extension_headers = rss.software_scaling.remove_extension_headers
      }
      for key, class in pairs(rss.software_scaling.classes) do
         table.insert(rss_config.classes, {
            name = key.name,
            order = key.order,
            filter = class.filter,
            continue = class.continue
         })
      end
      table.sort(rss_config.classes, function (a,b) return a.order < b.order end)
      for _, class in ipairs(rss_config.classes) do
         class.order = nil
         --print(class.name, class.filter, "continue="..tostring(class.continue))
      end
      --- XXX missing ifmib setup and finding Tap MACs
      workers["rss"..rssq] = probe.configure_rss_graph(rss_config, inputs, outputs)
   end

   -- for k,v in pairs(mellanox) do
   --    print(k)
   --    for _, q in ipairs(v.queues) do
   --       print("", q.id)
   --    end
   -- end

   -- Create a trivial app graph that only contains the control apps
   -- for the Mellanox driver, which sets up the queues and
   -- maintains interface counters.
   local ctrl_graph, need_ctrl = app_graph.new(), false
   for device, spec in pairs(mellanox) do
      local conf = {
         pciaddress = device,
         queues = spec.queues,
         recvq_size = spec.recvq_size
      }
      local driver = pci.device_info(device).driver
      app_graph.app(ctrl_graph, "ctrl_"..device,
                    require(driver).ConnectX, conf)
      need_ctrl = true
   end

   if need_ctrl then
      workers["mlx_ctrl"] = ctrl_graph
   end

   for name, graph in pairs(workers) do
      print("worker", name)
      print("", "apps:")
      for name, _ in pairs(graph.apps) do
         print("", "", name)
      end
      print("", "links:")
      for spec in pairs(graph.links) do
         print("", "", spec)
      end
   end

   return workers
end