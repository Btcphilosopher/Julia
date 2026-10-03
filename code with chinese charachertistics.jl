# ============================================================
# 电力执行价格分析系统
# 电力期权 / 电力合约 Strike Price 分析
# Julia
# ============================================================

using Printf
using Statistics

# ------------------------------------------------------------
# 电力合约
# ------------------------------------------------------------

struct 电力合约
    名称::String
    执行价格::Float64      # 元/MWh
    市场价格::Float64      # 元/MWh
    合约容量::Float64      # MW
    合约小时数::Float64
    类型::Symbol           # :看涨 或 :看跌
end

# ------------------------------------------------------------
# 计算期权内在价值
# ------------------------------------------------------------

function 计算内在价值(合约::电力合约)

    if 合约.类型 == :看涨
        return max(
            合约.市场价格 - 合约.执行价格,
            0.0
        )

    elseif 合约.类型 == :看跌
        return max(
            合约.执行价格 - 合约.市场价格,
            0.0
        )

    else
        error("未知的期权类型")
    end
end

# ------------------------------------------------------------
# 计算合约总价值
# ------------------------------------------------------------

function 计算合约价值(合约::电力合约)

    每兆瓦时价值 = 计算内在价值(合约)

    总电量 =
        合约.合约容量 *
        合约.合约小时数

    return 每兆瓦时价值 * 总电量
end

# ------------------------------------------------------------
# 判断是否应该执行
# ------------------------------------------------------------

function 判断执行(合约::电力合约)

    if 合约.类型 == :看涨

        return 合约.市场价格 > 合约.执行价格

    elseif 合约.类型 == :看跌

        return 合约.市场价格 < 合约.执行价格

    end

    return false
end

# ------------------------------------------------------------
# 电价敏感性分析
# ------------------------------------------------------------

function 电价敏感性分析(
    执行价格::Float64,
    电价范围::Vector{Float64},
    类型::Symbol
)

    println()
    println("========================================")
    println("电力执行价格敏感性分析")
    println("========================================")

    for 市场价格 in 电价范围

        if 类型 == :看涨
            收益 = max(
                市场价格 - 执行价格,
                0.0
            )
        else
            收益 = max(
                执行价格 - 市场价格,
                0.0
            )
        end

        @printf(
            "市场电价：%8.2f 元/MWh | 内在价值：%8.2f 元/MWh\n",
            市场价格,
            收益
        )
    end
end

# ------------------------------------------------------------
# 投资组合统计
# ------------------------------------------------------------

function 投资组合统计(
    合约列表::Vector{电力合约}
)

    总价值 = 0.0
    执行数量 = 0

    for 合约 in 合约列表

        价值 = 计算合约价值(合约)

        总价值 += 价值

        if 判断执行(合约)
            执行数量 += 1
        end
    end

    println()
    println("========================================")
    println("投资组合统计")
    println("========================================")

    @printf(
        "合约数量：%d\n",
        length(合约列表)
    )

    @printf(
        "当前可执行合约：%d\n",
        执行数量
    )

    @printf(
        "组合内在价值：%.2f 元\n",
        总价值
    )

    return 总价值
end

# ------------------------------------------------------------
# 创建电力合约
# ------------------------------------------------------------

合约1 = 电力合约(
    "华东基荷电力",
    420.0,
    510.0,
    100.0,
    24.0,
    :看涨
)

合约2 = 电力合约(
    "华北峰值电力",
    680.0,
    620.0,
    50.0,
    6.0,
    :看跌
)

合约3 = 电力合约(
    "南方电力",
    450.0,
    470.0,
    80.0,
    12.0,
    :看涨
)

合约列表 = [
    合约1,
    合约2,
    合约3
]

# ------------------------------------------------------------
# 输出每份合约
# ------------------------------------------------------------

println("╔══════════════════════════════════════╗")
println("║       中国电力执行价格分析系统       ║")
println("╚══════════════════════════════════════╝")

for 合约 in 合约列表

    内在价值 = 计算内在价值(合约)
    总价值 = 计算合约价值(合约)
    是否执行 = 判断执行(合约)

    println()
    println("合约：", 合约.名称)
    println("执行价格：", 合约.执行价格, " 元/MWh")
    println("市场价格：", 合约.市场价格, " 元/MWh")
    println("合约容量：", 合约.合约容量, " MW")
    println("合约类型：", 合约.类型)

    @printf(
        "内在价值：%.2f 元/MWh\n",
        内在价值
    )

    @printf(
        "合约价值：%.2f 元\n",
        总价值
    )

    println(
        "执行状态：",
        是否执行 ? "可以执行" : "暂不执行"
    )
end

# ------------------------------------------------------------
# 执行价格敏感性
# ------------------------------------------------------------

电价敏感性分析(
    420.0,
    collect(200.0:50.0:800.0),
    :看涨
)

# ------------------------------------------------------------
# 投资组合
# ------------------------------------------------------------

投资组合统计(合约列表)







# ============================================================
# Dianli Zhixing Jiage Fenxi Xitong
# Dianli Qiquan / Dianli He Yue Strike Price Fenxi
# Julia
# ============================================================

using Printf
using Statistics

# ------------------------------------------------------------
# Dianli Heyue
# ------------------------------------------------------------

struct DianliHeyue
    Mingcheng::String
    ZhixingJiage::Float64       # yuan/MWh
    ShichangJiage::Float64      # yuan/MWh
    HeyueRongliang::Float64     # MW
    HeyueXiaoshi::Float64
    Leixing::Symbol              # :kan_zhang huo :kan_die
end

# ------------------------------------------------------------
# Jisuan Qiquan Neizai Jiazhi
# ------------------------------------------------------------

function jisuan_neizai_jiazhi(heyue::DianliHeyue)

    if heyue.Leixing == :kan_zhang

        return max(
            heyue.ShichangJiage - heyue.ZhixingJiage,
            0.0
        )

    elseif heyue.Leixing == :kan_die

        return max(
            heyue.ZhixingJiage - heyue.ShichangJiage,
            0.0
        )

    else
        error("Weizhi de qiquan leixing")
    end
end

# ------------------------------------------------------------
# Jisuan Heyue Zong Jiazhi
# ------------------------------------------------------------

function jisuan_heyue_jiazhi(heyue::DianliHeyue)

    meizhao_washi_jiazhi =
        jisuan_neizai_jiazhi(heyue)

    zong_dianliang =
        heyue.HeyueRongliang *
        heyue.HeyueXiaoshi

    return meizhao_washi_jiazhi * zong_dianliang
end

# ------------------------------------------------------------
# Panduan Shifou Zhixing
# ------------------------------------------------------------

function panduan_zhixing(heyue::DianliHeyue)

    if heyue.Leixing == :kan_zhang

        return heyue.ShichangJiage >
               heyue.ZhixingJiage

    elseif heyue.Leixing == :kan_die

        return heyue.ShichangJiage <
               heyue.ZhixingJiage
    end

    return false
end

# ------------------------------------------------------------
# Dianjia Min'ganxing Fenxi
# ------------------------------------------------------------

function dianjia_minganxing_fenxi(
    zhixing_jiage::Float64,
    dianjia_fanwei::Vector{Float64},
    leixing::Symbol
)

    println()
    println("========================================")
    println("Dianli Zhixing Jiage Min'ganxing Fenxi")
    println("========================================")

    for shichang_jiage in dianjia_fanwei

        if leixing == :kan_zhang

            shouyi = max(
                shichang_jiage - zhixing_jiage,
                0.0
            )

        else

            shouyi = max(
                zhixing_jiage - shichang_jiage,
                0.0
            )
        end

        @printf(
            "Shichang dianjia: %8.2f yuan/MWh | Neizai jiazhi: %8.2f yuan/MWh\n",
            shichang_jiage,
            shouyi
        )
    end
end

# ------------------------------------------------------------
# Touzi Zuhe Tongji
# ------------------------------------------------------------

function touzi_zuhe_tongji(
    heyue_liebiao::Vector{DianliHeyue}
)

    zong_jiazhi = 0.0
    zhixing_shuliang = 0

    for heyue in heyue_liebiao

        jiazhi = jisuan_heyue_jiazhi(heyue)

        zong_jiazhi += jiazhi

        if panduan_zhixing(heyue)
            zhixing_shuliang += 1
        end
    end

    println()
    println("========================================")
    println("Touzi Zuhe Tongji")
    println("========================================")

    @printf(
        "Heyue shuliang: %d\n",
        length(heyue_liebiao)
    )

    @printf(
        "Dangqian keyi zhixing heyue: %d\n",
        zhixing_shuliang
    )

    @printf(
        "Zuhe neizai jiazhi: %.2f yuan\n",
        zong_jiazhi
    )

    return zong_jiazhi
end

# ------------------------------------------------------------
# Chuangjian Dianli Heyue
# ------------------------------------------------------------

heyue1 = DianliHeyue(
    "Huadong Jidian Dianli",
    420.0,
    510.0,
    100.0,
    24.0,
    :kan_zhang
)

heyue2 = DianliHeyue(
    "Huabei Fengzhi Dianli",
    680.0,
    620.0,
    50.0,
    6.0,
    :kan_die
)

heyue3 = DianliHeyue(
    "Nanfang Dianli",
    450.0,
    470.0,
    80.0,
    12.0,
    :kan_zhang
)

heyue_liebiao = [
    heyue1,
    heyue2,
    heyue3
]

# ------------------------------------------------------------
# Xianshi Heyue
# ------------------------------------------------------------

println("╔══════════════════════════════════════╗")
println("║      Zhongguo Dianli Zhixing Jiage Fenxi       ║")
println("╚══════════════════════════════════════╝")

for heyue in heyue_liebiao

    neizai_jiazhi =
        jisuan_neizai_jiazhi(heyue)

    zong_jiazhi =
        jisuan_heyue_jiazhi(heyue)

    shifou_zhixing =
        panduan_zhixing(heyue)

    println()
    println("Heyue: ", heyue.Mingcheng)

    println(
        "Zhixing jiage: ",
        heyue.ZhixingJiage,
        " yuan/MWh"
    )

    println(
        "Shichang jiage: ",
        heyue.ShichangJiage,
        " yuan/MWh"
    )

    println(
        "Heyue rongliang: ",
        heyue.HeyueRongliang,
        " MW"
    )

    println(
        "Heyue leixing: ",
        heyue.Leixing
    )

    @printf(
        "Neizai jiazhi: %.2f yuan/MWh\n",
        neizai_jiazhi
    )

    @printf(
        "Heyue jiazhi: %.2f yuan\n",
        zong_jiazhi
    )

    println(
        "Zhixing zhuangtai: ",
        shifou_zhixing ?
        "Keyi zhixing" :
        "Zanbu zhixing"
    )
end

# ------------------------------------------------------------
# Zhixing Jiage Min'ganxing
# ------------------------------------------------------------

dianjia_minganxing_fenxi(
    420.0,
    collect(200.0:50.0:800.0),
    :kan_zhang
)

# ------------------------------------------------------------
# Touzi Zuhe
# ------------------------------------------------------------

touzi_zuhe_tongji(
    heyue_liebiao
)
