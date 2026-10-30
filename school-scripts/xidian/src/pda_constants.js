// Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0
// Exact default idsDio UA from traintime_pda/lib/repository/network_client.dart.
export const PDA_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 XDYou/2.0.0";
export const IDS_LOGIN = "https://ids.xidian.edu.cn/authserver/login";
export const IDS_ORIGIN = "https://ids.xidian.edu.cn";
export const PDA_TARGETS = {
  ehall: {
    origin: "https://ehall.xidian.edu.cn",
    service: "https://ehall.xidian.edu.cn/appShow?appId=4770397878132218",
    probe: "https://ehall.xidian.edu.cn/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do",
  },
  yjspt: {
    origin: "https://yjspt.xidian.edu.cn",
    service: "https://yjspt.xidian.edu.cn/",
    probe: "https://yjspt.xidian.edu.cn/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do",
  },
};
