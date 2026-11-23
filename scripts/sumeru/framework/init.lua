-- sumeru framework 门面：require("sumeru.framework") 返回核心设施集合。
local Architecture=require("sumeru.framework.Architecture")
local Container=require("sumeru.framework.Container")
local TypeEvent=require("sumeru.framework.TypeEvent")
local CommandBus=require("sumeru.framework.CommandBus")
local Bindable=require("sumeru.framework.Bindable")

return {
 Architecture=Architecture,
 Container=Container,
 TypeEvent=TypeEvent,
 CommandBus=CommandBus,
 Bindable=Bindable,
}
