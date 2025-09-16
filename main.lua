--[[
    mpv-homehub

    This script turns mpv into a minimal client for your favorite home media server(s).
--]]

local mp = require 'mp'

local o = require 'src.core.options'

-- setting the package paths
package.path = mp.command_native({'expand-path', o.module_directory}) .. '/?.lua;' .. package.path

local homehub = require 'src.core.init'
homehub.start()
