-- 广告 toolkit 公开入口；业务只依赖 ShowRewardVideo，不直接依赖宿主细节。
-- 免广与次数规则、广告奖励统一入口按路径单独引用：sumeru.toolkit.adkit.AdFree、sumeru.toolkit.adkit.AdReward。
return require("sumeru.toolkit.adkit.AdKit")
