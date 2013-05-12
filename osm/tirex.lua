--
-- Lua script for interface Tirex engine
--
--
-- Copyright (C) 2013, Hiroshi Miura
--
--    This program is free software: you can redistribute it and/or modify
--    it under the terms of the GNU Affero General Public License as published by
--    the Free Software Foundation, either version 3 of the License, or
--    any later version.
--
--    This program is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU Affero General Public License for more details.
--
--    You should have received a copy of the GNU Affero General Public License
--    along with this program.  If not, see <http://www.gnu.org/licenses/>.
--

local shmem = ngx.shared.osm_tirex

local udp = ngx.socket.udp
local timerat = ngx.timer.at
local time = ngx.time
local null = ngx.null
local sleep = ngx.sleep

local insert = table.insert
local concat = table.concat

local sub = string.sub
local len = string.len
local find = string.find
local gmatch = string.gmatch
local format = string.format

local pairs = pairs
local unpack = unpack
local setmetatable = setmetatable
local tonumber = tonumber
local tostring = tostring
local error = error
local setmetatable = setmetatable

module(...)

_VERSION = '0.10'

-- ------------------------------------
-- Syncronize thread functions
--
--   thread(1)
--       get_handle(key)
--       do work
--       store work result somewhere
--       send_signal(key)
--       return result
--
--   thread(2)
--       get_handle(key) fails then
--       wait_singal(key)
--       return result what thread(1) done
--
--   to syncronize amoung nginx threads
--   we use ngx.shared.DICT interface.
--   
--   Here we use ngx.shared.stats
--   you need to set /etc/conf.d/lua.conf
--      ngx_shared_dict stats 10m; 
--
--   if these functions returns 'nil'
--   status is undefined
--   something wrong
--
--   status definitions
--    key is not exist:    neutral
--    key is exist: someone got work token
--       val = 0:     now working
--       val > 0:     work is finished
--
--    key will be expired in timeout sec
--    we can use same key after timeout passed
--
-- ------------------------------------

--
--  if key exist, it returns false
--  else it returns true
--
function get_handle(key, timeout, flag)
    local success,err,forcible = shmem:add(key, 0, timeout, flag)
    if success ~= false then
        return key, ''
    end
    return nil, ''
end

-- return nil if timeout in wait
--
function wait_signal(key, timeout)
    local timeout = tonumber(timeout)
    for i=0, timeout do
        local val, flag = shmem:get(key)
        if val then
            if flag == 3 then
                return true
            end
            sleep(1)
        else
            return nil
        end
    end
    return nil
end

-- function: serialize_msg
-- argument: table msg
--     hash table {key1=val1, key2=val2,....}
-- return: string
--     should be 'key1=val1\nkey2=val2\n....\n'
--
function serialize_msg (msg)
    local str = ''
    for k,v in pairs(msg) do
        str = str .. k .. '=' .. tostring(v) .. '\n'
    end
    return str
end

-- function: deserialize_msg
-- arguments: string str: recieved message from tirex
--     should be 'key1=val1\nkey2=val2\n....\n'
-- return: table
--     hash table {key1=val1, key2=val2,....}
function deserialize_msg (str) 
    local msg = {}
    for line in gmatch(str, "[^\n]+") do
        m,_,k,v = find(line,"([^=]+)=(.+)")
        if  k ~= '' then
            msg[k]=v
        end
    end
    return msg
end

-- ========================================================
--  It does not share context and global vals/funcs
--
local tirex_handler
tirex_handler = function (premature)
    local tirexsock = 'unix:/var/run/tirex/master.sock'
    local tirex_cmd_max_size = 512
    local shmem = ngx.shared.osm_tirex

    if premature then
        -- clean up
        shmem:delete('_tirex_handler')
        return
    end

    local udpsock = ngx.socket.udp()
    udpsock:setpeername(tirexsock)

    for i = 0, 10000 do
        -- send all requests first...
        local indexes = shmem:get_keys(10)
        for key,index in pairs(indexes) do
	    if index ~= '_tirex_handler' then
                local req, flag = shmem:get(index)
		if flag == 1 then
                    local ok,err=udpsock:send(req)
                    if not ok then
                        ngx.log(ngx.DEBUG, err)
                    else
                        shmem:replace(index, req, 300, 2)
	            end
                end
            end
        end
        -- then receive response
        local data, err = udpsock:receive(tirex_cmd_max_size)
        if data then
            -- deserialize
            local msg = {}
            for line in gmatch(data, "[^\n]+") do
                m,_,k,v = find(line,"([^=]+)=(.+)")
                if  k ~= '' then
                    msg[k]=v
                end
            end
            local index = format("%s:%d:%d:%d", msg["map"], msg["x"], msg["y"], msg["z"])

            -- send_signal to client context
            local ok, err = shmem:set(index, data, 300, 3)
            if not ok then
                ngx.log(ngx.DEBUG, "error in incr")
            end
        else
            ngx.log(ngx.DEBUG, err)
        end
    end
    udpsock:close()
    -- call myself
    timerat(0.1, tirex_handler)
end

-- function: request_tirex_render
--  enqueue request to tirex server
--
function request_render(map, mx, my, mz, id)
    -- Create request command
    local index = format("%s:%d:%d:%d",map, mx, my, mz)
    local priority = 8
    local req = serialize_msg({
        ["id"]   = tostring(id);
        ["type"] = 'metatile_enqueue_request';
        ["prio"] = priority;
        ["map"]  = map;
        ["x"]    = mx;
        ["y"]    = my;
        ["z"]    = mz})
    local ok, err, forcible = shmem:set(index, req, 0, 1)
    if not ok then
        return nil, err
    end

    local handle = get_handle('_tirex_handler', 0, 0)
    if handle then
        -- only single light thread can handle Tirex
        timerat(0, tirex_handler)
    end

    return true
end

-- funtion: send_request
-- argument: map, x, y, z
-- return:   true or nil
--
function send_request (map, x, y, z)
    local mx = x - x % 8
    local my = y - y % 8
    local mz = z
    local id = time()
    local index = format("%s:%d:%d:%d",map, mx, my, mz)

    local ok, err = get_handle(index, 300, 0)
    if not ok then
        -- someone have already start Tirex session
        -- wait other side(*), sync..
        return wait_signal(index, 30)
    end

    -- Ask Tirex session
    local ok = request_render(map, mx, my, mz, id)
    if not ok then
        return nil
    end
    return wait_signal(index, 30)
end

local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}

setmetatable(_M, class_mt)
