/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

// Verified from the E-Hall classroom.buildings result on 2026-11-01.
// Public building names/codes only. Refresh through a reviewed script update.
const entries = [
  {
    building: "广研院",
    buildingId: "G",
    campus: "N",
  },
  {
    building: "阶梯教室",
    buildingId: "L",
    campus: "N",
  },
  {
    building: "西大楼",
    buildingId: "X",
    campus: "N",
  },
  {
    building: "东",
    buildingId: "东大楼",
    campus: "N",
  },
  {
    building: "北校区主楼",
    buildingId: "主楼II区-111",
    campus: "N",
  },
  {
    building: "北校区体育馆",
    buildingId: "北校区体育馆",
    campus: "N",
  },
  {
    building: "北图",
    buildingId: "北校区图书馆",
    campus: "N",
  },
  {
    building: "北行政",
    buildingId: "北校区行政楼",
    campus: "N",
  },
  {
    building: "计算中心",
    buildingId: "计算中心",
    campus: "N",
  },
  {
    building: "A教学楼",
    buildingId: "A",
    campus: "S",
  },
  {
    building: "B教学楼",
    buildingId: "B",
    campus: "S",
  },
  {
    building: "C教学楼",
    buildingId: "C",
    campus: "S",
  },
  {
    building: "D教学楼",
    buildingId: "D",
    campus: "S",
  },
  {
    building: "E教学楼I区",
    buildingId: "EI",
    campus: "S",
  },
  {
    building: "E教学楼II区",
    buildingId: "EII",
    campus: "S",
  },
  {
    building: "E教学楼III区",
    buildingId: "EIII",
    campus: "S",
  },
  {
    building: "F教学楼",
    buildingId: "F",
    campus: "S",
  },
  {
    building: "G教学楼",
    buildingId: "G教学楼",
    campus: "S",
  },
  {
    building: "信远教学楼I区",
    buildingId: "信远I",
    campus: "S",
  },
  {
    building: "信远教学楼II区",
    buildingId: "信远II",
    campus: "S",
  },
  {
    building: "丁香1号书院",
    buildingId: "11#",
    campus: "S",
  },
  {
    building: "丁香2号书院12#",
    buildingId: "丁香2号书院12#",
    campus: "S",
  },
  {
    building: "海棠八号书院",
    buildingId: "海棠八号书院",
    campus: "S",
  },
  {
    building: "海棠九号书院",
    buildingId: "海棠九号书院",
    campus: "S",
  },
  {
    building: "体育场",
    buildingId: "体育场",
    campus: "S",
  },
  {
    building: "艺教中心",
    buildingId: "艺教中心",
    campus: "S",
  },
  {
    building: "工训中心",
    buildingId: "工训中心",
    campus: "S",
  },
  {
    building: "行政辅楼",
    buildingId: "行政辅楼",
    campus: "S",
  },
  {
    building: "大学生活动中心",
    buildingId: "大活",
    campus: "S",
  },
  {
    building: "图书馆",
    buildingId: "图书馆",
    campus: "S",
  },
  {
    building: "实验室（排课）",
    buildingId: "实验室",
    campus: "S",
  },
  {
    building: "网安大楼",
    buildingId: "W",
    campus: "S",
  },
  {
    building: "丁香宿舍楼",
    buildingId: "丁香宿舍楼",
    campus: "S",
  },
  {
    building: "国工",
    buildingId: "国家工程中心",
    campus: "S",
  },
  {
    building: "海棠宿舍楼",
    buildingId: "海棠宿舍楼",
    campus: "S",
  },
  {
    building: "竹园宿舍楼",
    buildingId: "竹园宿舍楼",
    campus: "S",
  },
];

export function classroomDirectory() {
  return entries.map((item) => ({ ...item }));
}
