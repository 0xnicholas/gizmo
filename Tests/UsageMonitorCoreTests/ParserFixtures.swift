import Foundation

/// 录制响应 fixture:形状取自 `docs/research/*.md` 记录的实测响应(值已替换为示例值,无任何密钥)。
/// 每个 fixture 的出处写在定义处;字段形状/单位/时间格式与调研文档逐字对齐,
/// 解析层回归时不需要重连真实端点。
enum ParserFixtures {
    static func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    /// DeepSeek `GET /user/balance` 实测形状(字段均为 string;见 deepseek-usage-source.md「端点规格 1」)。
    static let deepseekBalance = """
    {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"62.47","granted_balance":"3.20","topped_up_balance":"59.27"}]}
    """

    static let deepseekMultiCurrency = """
    {"is_available":true,"balance_infos":[
      {"currency":"CNY","total_balance":"8.00","granted_balance":"0.00","topped_up_balance":"8.00"},
      {"currency":"USD","total_balance":"1000.00","granted_balance":"0.00","topped_up_balance":"1000.00"}
    ]}
    """

    static let deepseekUnavailable = """
    {"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}
    """

    /// Kimi `/coding/v1/usages` 实测形状(user 的 membership 与平行上限;kimi-coding-usage-source.md「端点规格 1)」)。
    static let kimiUsages = """
    {"user":{"userId":"u-1","region":"REGION_CN","membership":{"level":"LEVEL_INTERMEDIATE"},"businessId":"b-1"},
     "usage":{"limit":"100","used":"98","remaining":"2","resetTime":"2026-09-10T08:24:54Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                "detail":{"used":"10","limit":"100","remaining":"90","resetTime":"2026-09-09T06:24:54Z"}}],
     "parallel":{"limit":"20"},
     "boosterWallet":{"status":"STATUS_ACTIVE",
                      "balance":{"amount":"2500000000","amountLeft":"3500000","unit":"UNIT_CURRENCY","type":"BOOSTER"},
                      "monthlyChargeLimit":{"priceInCents":"10000","currency":"CNY"},
                      "monthlyUsed":{"priceInCents":"0","currency":"CNY"}},
     "authentication":{"method":"METHOD_API_KEY","scope":"FEATURE_CODING"},
     "subType":"TYPE_PURCHASE","domain":"DOMAIN_NEXUS","totalQuota":{}}
    """

    /// Kimi `/coding/v1/me` 实测形状(kimi-coding-usage-source.md「端点规格 2)」)。
    static let kimiProfile = """
    {"user_id":"u-1","global_id":"g-1","nickname":"nick","status":"USER_STATUS_NORMAL","region":"REGION_CN",
     "user_level":25,"user_level_name":"Allegretto","domain":"DOMAIN_NEXUS","domain_name":"DOMAIN_NEXUS"}
    """

    /// GLM `/api/monitor/usage/quota/limit` 实测形状(Pro:5 小时 12,000 积分 / 7 天 60,000 积分;
    /// 数值逐字取自 glm-coding-usage-source.md「端点规格 1」的实测响应)。
    static let glmQuota = """
    {"code":200,"msg":"Operation successful","data":{
      "limits":[
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":641,"remaining":11358,"percentage":5,"nextResetTime":1788937420709},
        {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":44070,"remaining":15929,"percentage":73,"nextResetTime":1789177578997}
      ],
      "level":"pro"},
     "success":true}
    """

    /// GLM `/api/monitor/usage/model-usage`(日粒度,近 7 天桶;glm-coding-usage-source.md「端点规格 2」)。
    static let glmModelUsageDaily = """
    {"code":200,"data":{
      "x_time":["2026-09-03","2026-09-04","2026-09-05"],
      "modelCallCount":[0,245,246],
      "tokensUsage":[1000000,2500000,4000000],
      "totalUsage":{"totalModelCallCount":491,"totalTokensUsage":7500000,
        "modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":7500000,"sortOrder":1}]},
      "granularity":"daily"},
     "success":true}
    """
}
