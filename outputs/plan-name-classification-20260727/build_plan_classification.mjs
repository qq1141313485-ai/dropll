import fs from "node:fs/promises";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir =
  "/Users/drop/Documents/Codex/2026-07-21/q/work2/cai_tool_app/outputs/plan-name-classification-20260727";

const authorSeriesRows = [
  ["竞胜进球", "竞胜", "进球"],
  ["南枝青衣晚", "南枝青衣", "晚"],
  ["平局晚", "平局", "晚"],
  ["桂花今日抄底晚", "桂花", "今日抄底、晚"],
  ["小爱同学神之一手晚", "小爱同学", "神之一手、晚"],
  ["繁花半全场", "繁花", "半全场"],
  ["解语花红豆", "解语花", "红豆"],
  ["抄底风暴", "抄底 / 或完整名称", "风暴 / 或无"],
  ["相遇稳中", "相遇", "稳中"],
  ["彩虹抄底3.0", "彩虹 / 彩虹抄底", "抄底 3.0 / 3.0"],
  ["阿超进球", "阿超", "进球"],
  ["毒液以此为准", "毒液", "以此为准"],
  ["鸿哥晚", "鸿哥", "晚"],
  ["老嗣晚", "老嗣 / 解说员老嗣", "晚"],
  ["辉哥高赔", "辉哥", "高赔"],
  ["平头江山如画", "平头", "江山如画"],
  ["小玉稳中", "小玉", "稳中"],
  ["行者当家", "行者 / 或完整名称", "当家 / 或无"],
  ["胖哥禧悦", "胖哥 / 或完整名称", "禧悦 / 或无"],
  ["大白鲨蓝天系列", "大白鲨", "蓝天系列"],
  ["小米柒月", "小米 / 或完整名称", "柒月 / 或无"],
  ["翔哥足球", "翔哥", "足球"],
  ["胜利百灵鸟", "胜利 / 或完整名称", "百灵鸟 / 或无"],
  ["青衣早", "青衣", "早"],
  ["十五足球", "十五", "足球"],
  ["百忆足球", "百忆", "足球"],
  ["老崔扫盘系列3", "老崔", "扫盘系列 3"],
  ["锦鲤附体", "锦鲤", "附体"],
  ["竞胜总进球早场更新！", "竞胜", "总进球、早场"],
  ["幻影新起点", "幻影 / 或完整名称", "新起点 / 或无"],
  ["企鹅满地红", "企鹅 / 或完整名称", "满地红 / 或无"],
  ["水花有早场", "水花", "早场"],
  ["解说员老嗣（早场）", "解说员老嗣", "早场"],
  ["毒液早场更新了", "毒液", "早场"],
];

const standaloneAuthors = [
  "足球大数据",
  "江湖",
  "老崔",
  "小神童",
  "魔术",
  "天赐",
  "老宋",
  "嘟嘟",
  "朵朵",
  "大柒",
  "cc",
  "丽娜",
  "小闫",
  "壹迪",
  "聚金",
  "顺风",
  "博浪",
  "队长",
  "星光",
  "金迪",
  "招财兔",
  "耕耘",
  "豫北",
  "小小余",
  "吞金兽",
  "蓝白",
  "红冠",
  "常红",
  "米兰",
  "智能",
  "福地",
  "长红",
  "打火机",
  "平局哥",
  "柠檬",
  "红龍鱼",
  "红警",
  "胡子",
];

const compoundRows = [
  ["扫地僧，辉哥中赔", "扫地僧；辉哥 + 中赔"],
  ["雷速，金钥匙", "雷速；金钥匙"],
  ["剑兰，飞虎队", "剑兰；飞虎队"],
  ["随心，体育", "随心；体育"],
  ["世家，梅西半全场", "世家；梅西 + 半全场"],
  ["南枝，海尔，情人", "南枝；海尔；情人"],
  ["老凤祥，大重庆，女主角", "老凤祥；大重庆；女主角"],
  ["诚信，温暖", "诚信；温暖"],
  ["神之一手，小爱同学早", "神之一手；小爱同学 + 早"],
  ["上岸，鸿哥", "上岸；鸿哥"],
  ["颖宝，浩哥", "颖宝；浩哥"],
  ["桂花，解语花，明灯", "桂花；解语花；明灯"],
  ["福星，金淼", "福星；金淼"],
  ["超越，冰糖葫芦，星光", "超越；冰糖葫芦；星光"],
  ["1号牛总，抄底进球", "1号牛总；抄底 + 进球"],
  ["羊肉串，牛肉串", "羊肉串；牛肉串"],
  ["灵蛇，西瓜", "灵蛇；西瓜"],
  ["彤宝＋星巴克", "彤宝；星巴克"],
  ["老彩民，飞跃，牛头，飞虎队", "老彩民；飞跃；牛头；飞虎队"],
  ["好运来，旺旺", "好运来；旺旺"],
  ["人工智能，皇冠", "人工智能；皇冠"],
  ["五月花相遇，稳中中", "五月花；相遇 + 稳中中（待确认）"],
  ["金沙河，乐小星", "金沙河；乐小星"],
  ["辰龙，巧克力", "辰龙；巧克力"],
  ["章鱼哥，左岸", "章鱼哥；左岸"],
  ["木鱼，追梦", "木鱼；追梦"],
  [
    "今日看点，辉辉扫盘",
    "今日看点；辉辉 + 扫盘（待确认是否忽略“今日看点”）",
  ],
];

const classificationRows = [];
for (const [rawName, author, series] of authorSeriesRows) {
  classificationRows.push([
    classificationRows.length + 1,
    rawName,
    "作者+系列",
    author,
    series,
    "",
    "",
    "",
    "否",
    "否",
    "",
  ]);
}
for (const author of standaloneAuthors) {
  classificationRows.push([
    classificationRows.length + 1,
    author,
    "独立作者候选",
    author,
    "",
    "",
    "",
    "",
    "否",
    "否",
    "",
  ]);
}
for (const [rawName, splitSuggestion] of compoundRows) {
  classificationRows.push([
    classificationRows.length + 1,
    rawName,
    "多作者复合",
    splitSuggestion,
    "",
    "",
    "",
    "",
    "待确认",
    "否",
    "",
  ]);
}
classificationRows.push([
  classificationRows.length + 1,
  "昨日赛果",
  "建议忽略",
  "",
  "",
  "",
  "",
  "",
  "否",
  "是",
  "非计划内容，不创建计划",
]);

const confirmedSeries = [
  ["早", "时段"],
  ["晚", "时段"],
  ["早场", "时段"],
  ["晚场", "时段"],
  ["早单", "时段"],
  ["晚单", "时段"],
  ["上午场", "时段"],
  ["下午场", "时段"],
  ["夜场", "时段"],
  ["高赔", "赔率方向"],
  ["低配", "赔率方向"],
  ["半全场", "玩法"],
  ["2.0", "版本"],
  ["3.0", "版本"],
];

const candidateSeries = [
  ["中赔", "赔率方向"],
  ["进球", "玩法/主题"],
  ["总进球", "玩法/主题"],
  ["足球", "主题"],
  ["抄底", "主题"],
  ["今日抄底", "主题"],
  ["抄底进球", "主题"],
  ["抄底 3.0", "主题/版本"],
  ["扫盘", "主题"],
  ["扫盘系列 3", "主题/版本"],
  ["稳中", "主题"],
  ["稳中中", "主题"],
  ["神之一手", "主题"],
  ["以此为准", "主题"],
  ["红豆", "主题"],
  ["附体", "主题"],
  ["江山如画", "主题"],
  ["当家", "主题"],
  ["禧悦", "主题"],
  ["蓝天系列", "主题"],
  ["柒月", "主题"],
  ["新起点", "主题"],
  ["满地红", "主题"],
  ["风暴", "主题"],
  ["百灵鸟", "主题"],
];

const seriesRows = [
  ...confirmedSeries.map(([name, category]) => [
    name,
    category,
    "已确认",
    "是系列",
    "",
  ]),
  ...candidateSeries.map(([name, category]) => [
    name,
    category,
    "待确认",
    "",
    "",
  ]),
];

const workbook = Workbook.create();
const annotationSheet = workbook.worksheets.add("分类标注");
const seriesSheet = workbook.worksheets.add("系列词确认");
const guideSheet = workbook.worksheets.add("填写说明");

for (const sheet of [annotationSheet, seriesSheet, guideSheet]) {
  sheet.showGridLines = false;
}

const green = "#0A8F68";
const greenDark = "#07684D";
const greenSoft = "#E8F6F1";
const ink = "#1C2421";
const muted = "#66706C";
const line = "#D9E1DE";
const editable = "#FFF7D6";
const warning = "#FFF0D6";
const dangerSoft = "#FDECEC";
const white = "#FFFFFF";

annotationSheet.getRange("A1:K1").merge();
annotationSheet.getRange("A1").values = [["计划名称分类标注表"]];
annotationSheet.getRange("A2:K2").merge();
annotationSheet.getRange("A2").values = [[
  "请重点填写黄色区域。确认建议可直接选择；需要调整时，请补充最终作者主体和最终系列。",
]];

annotationSheet.getRange("A3:J3").values = [[
  "名称总数",
  "",
  "已标注",
  "",
  "待标注",
  "",
  "多作者复合",
  "",
  "建议忽略",
  "",
]];
const classificationStartRow = 7;
const classificationEndRow = classificationStartRow + classificationRows.length - 1;
annotationSheet.getRange("B3").formulas = [[
  `=COUNTA(B${classificationStartRow}:B${classificationEndRow})`,
]];
annotationSheet.getRange("D3").formulas = [[
  `=COUNTIF(F${classificationStartRow}:F${classificationEndRow},"?*")`,
]];
annotationSheet.getRange("F3").formulas = [[
  `=B3-D3`,
]];
annotationSheet.getRange("H3").formulas = [[
  `=COUNTIF(C${classificationStartRow}:C${classificationEndRow},"多作者复合")`,
]];
annotationSheet.getRange("J3").formulas = [[
  `=COUNTIF(C${classificationStartRow}:C${classificationEndRow},"建议忽略")`,
]];

annotationSheet.getRange("A5:K5").merge();
annotationSheet.getRange("A5").values = [[
  "建议内容仅供确认，不会自动合并。带“晚、早、高赔、低配、半全场、2.0、3.0”等词通常应归入同一作者下的不同系列。",
]];

const headers = [[
  "序号",
  "原始名称",
  "当前分类",
  "建议作者主体/拆分",
  "建议系列",
  "你的处理结果",
  "最终作者主体",
  "最终系列",
  "是否拆分多作者",
  "是否忽略",
  "备注",
]];
annotationSheet.getRange("A6:K6").values = headers;
annotationSheet
  .getRange(`A${classificationStartRow}:K${classificationEndRow}`)
  .values = classificationRows;

const annotationTable = annotationSheet.tables.add(
  `A6:K${classificationEndRow}`,
  true,
  "PlanClassificationTable",
);
annotationTable.style = "TableStyleMedium2";
annotationTable.showBandedRows = true;
annotationTable.showFilterButton = true;

annotationSheet
  .getRange(`F${classificationStartRow}:F${classificationEndRow}`)
  .dataValidation = {
  rule: {
    type: "list",
    values: [
      "确认建议",
      "修改",
      "独立作者",
      "多作者拆分",
      "忽略",
      "暂不确定",
    ],
  },
};
annotationSheet
  .getRange(`I${classificationStartRow}:J${classificationEndRow}`)
  .dataValidation = {
  rule: { type: "list", values: ["是", "否", "待确认"] },
};

const resultRange = annotationSheet.getRange(
  `F${classificationStartRow}:F${classificationEndRow}`,
);
resultRange.conditionalFormats.add("containsText", {
  text: "确认建议",
  format: { fill: "#DDF4E9", font: { bold: true, color: greenDark } },
});
resultRange.conditionalFormats.add("containsText", {
  text: "修改",
  format: { fill: warning, font: { bold: true, color: "#9A5B00" } },
});
resultRange.conditionalFormats.add("containsText", {
  text: "忽略",
  format: { fill: dangerSoft, font: { bold: true, color: "#A43434" } },
});
resultRange.conditionalFormats.add("containsText", {
  text: "暂不确定",
  format: { fill: "#FFFBEA", font: { color: "#7A6A18" } },
});

annotationSheet.getRange(`J${classificationStartRow}:J${classificationEndRow}`)
  .conditionalFormats.add("containsText", {
    text: "是",
    format: { fill: dangerSoft, font: { bold: true, color: "#A43434" } },
  });

annotationSheet.getRange("A1:K1").format = {
  fill: green,
  font: { name: "PingFang SC", bold: true, color: white, size: 18 },
  horizontalAlignment: "left",
  verticalAlignment: "center",
};
annotationSheet.getRange("A2:K2").format = {
  fill: greenSoft,
  font: { name: "PingFang SC", color: greenDark, size: 10 },
  horizontalAlignment: "left",
  verticalAlignment: "center",
  wrapText: true,
};
annotationSheet.getRange("A3:J3").format = {
  fill: white,
  font: { name: "PingFang SC", color: muted, size: 10 },
  horizontalAlignment: "center",
  verticalAlignment: "center",
  borders: { preset: "all", style: "thin", color: line },
};
annotationSheet.getRange("B3,D3,F3,H3,J3").format = {
  fill: greenSoft,
  font: { name: "PingFang SC", bold: true, color: greenDark, size: 12 },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
annotationSheet.getRange("A5:K5").format = {
  fill: "#F4F7F6",
  font: { name: "PingFang SC", color: muted, italic: true, size: 10 },
  wrapText: true,
  verticalAlignment: "center",
};
annotationSheet.getRange("A6:K6").format = {
  fill: greenDark,
  font: { name: "PingFang SC", bold: true, color: white, size: 10 },
  horizontalAlignment: "center",
  verticalAlignment: "center",
  wrapText: true,
};
annotationSheet
  .getRange(`A${classificationStartRow}:K${classificationEndRow}`)
  .format = {
  font: { name: "PingFang SC", color: ink, size: 10 },
  verticalAlignment: "center",
  wrapText: true,
  borders: {
    insideHorizontal: { style: "thin", color: "#E5EBE8" },
    bottom: { style: "thin", color: line },
  },
};
annotationSheet
  .getRange(`F${classificationStartRow}:K${classificationEndRow}`)
  .format.fill = editable;
annotationSheet
  .getRange(`A${classificationStartRow}:A${classificationEndRow}`)
  .format.horizontalAlignment = "center";
annotationSheet
  .getRange(`C${classificationStartRow}:C${classificationEndRow}`)
  .format.horizontalAlignment = "center";
annotationSheet
  .getRange(`F${classificationStartRow}:J${classificationEndRow}`)
  .format.horizontalAlignment = "center";

const annotationWidths = [7, 28, 15, 29, 23, 17, 24, 22, 16, 12, 32];
for (let index = 0; index < annotationWidths.length; index += 1) {
  annotationSheet
    .getRangeByIndexes(0, index, classificationEndRow, 1)
    .format.columnWidth = annotationWidths[index];
}
annotationSheet.getRange("1:1").format.rowHeight = 34;
annotationSheet.getRange("2:2").format.rowHeight = 30;
annotationSheet.getRange("3:3").format.rowHeight = 28;
annotationSheet.getRange("4:4").format.rowHeight = 9;
annotationSheet.getRange("5:5").format.rowHeight = 34;
annotationSheet.getRange("6:6").format.rowHeight = 34;
annotationSheet
  .getRange(`${classificationStartRow}:${classificationEndRow}`)
  .format.rowHeight = 38;
annotationSheet.freezePanes.freezeRows(6);
annotationSheet.freezePanes.freezeColumns(2);

seriesSheet.getRange("A1:E1").merge();
seriesSheet.getRange("A1").values = [["系列词确认"]];
seriesSheet.getRange("A2:E2").merge();
seriesSheet.getRange("A2").values = [[
  "请确认这些词是否属于作者下面的“系列”。黄色列可直接选择：是系列、不是系列、需要讨论。",
]];
seriesSheet.getRange("A4:E4").values = [[
  "系列词",
  "建议分类",
  "当前状态",
  "你的确认",
  "备注",
]];
const seriesStartRow = 5;
const seriesEndRow = seriesStartRow + seriesRows.length - 1;
seriesSheet.getRange(`A${seriesStartRow}:E${seriesEndRow}`).values = seriesRows;
const seriesTable = seriesSheet.tables.add(
  `A4:E${seriesEndRow}`,
  true,
  "SeriesConfirmationTable",
);
seriesTable.style = "TableStyleMedium2";
seriesTable.showBandedRows = true;
seriesTable.showFilterButton = true;
seriesSheet.getRange(`D${seriesStartRow}:D${seriesEndRow}`).dataValidation = {
  rule: {
    type: "list",
    values: ["是系列", "不是系列", "需要讨论"],
  },
};
seriesSheet.getRange(`D${seriesStartRow}:D${seriesEndRow}`)
  .conditionalFormats.add("containsText", {
    text: "是系列",
    format: { fill: "#DDF4E9", font: { bold: true, color: greenDark } },
  });
seriesSheet.getRange(`D${seriesStartRow}:D${seriesEndRow}`)
  .conditionalFormats.add("containsText", {
    text: "不是系列",
    format: { fill: dangerSoft, font: { bold: true, color: "#A43434" } },
  });
seriesSheet.getRange(`D${seriesStartRow}:D${seriesEndRow}`)
  .conditionalFormats.add("containsText", {
    text: "需要讨论",
    format: { fill: warning, font: { bold: true, color: "#9A5B00" } },
  });

seriesSheet.getRange("A1:E1").format = {
  fill: green,
  font: { name: "PingFang SC", bold: true, color: white, size: 18 },
  verticalAlignment: "center",
};
seriesSheet.getRange("A2:E2").format = {
  fill: greenSoft,
  font: { name: "PingFang SC", color: greenDark, size: 10 },
  wrapText: true,
  verticalAlignment: "center",
};
seriesSheet.getRange("A4:E4").format = {
  fill: greenDark,
  font: { name: "PingFang SC", bold: true, color: white, size: 10 },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
seriesSheet.getRange(`A${seriesStartRow}:E${seriesEndRow}`).format = {
  font: { name: "PingFang SC", color: ink, size: 10 },
  verticalAlignment: "center",
  borders: {
    insideHorizontal: { style: "thin", color: "#E5EBE8" },
    bottom: { style: "thin", color: line },
  },
};
seriesSheet.getRange(`D${seriesStartRow}:E${seriesEndRow}`).format.fill =
  editable;
seriesSheet.getRange(`B${seriesStartRow}:D${seriesEndRow}`)
  .format.horizontalAlignment = "center";
const seriesWidths = [22, 18, 16, 18, 36];
for (let index = 0; index < seriesWidths.length; index += 1) {
  seriesSheet
    .getRangeByIndexes(0, index, seriesEndRow, 1)
    .format.columnWidth = seriesWidths[index];
}
seriesSheet.getRange("1:1").format.rowHeight = 34;
seriesSheet.getRange("2:2").format.rowHeight = 32;
seriesSheet.getRange("3:3").format.rowHeight = 9;
seriesSheet.getRange("4:4").format.rowHeight = 30;
seriesSheet.getRange(`${seriesStartRow}:${seriesEndRow}`).format.rowHeight = 27;
seriesSheet.freezePanes.freezeRows(4);

guideSheet.getRange("A1:F1").merge();
guideSheet.getRange("A1").values = [["填写说明"]];
guideSheet.getRange("A3:F3").merge();
guideSheet.getRange("A3").values = [[
  "目标：把每个来源名称稳定归到“作者主体 + 系列”，避免同一个作者每天生成新的计划。",
]];
guideSheet.getRange("A5:B10").values = [
  ["步骤", "怎么填写"],
  ["1", "先在“系列词确认”表确认哪些词属于系列。"],
  ["2", "回到“分类标注”，在“你的处理结果”选择对应选项。"],
  ["3", "选择“修改”时，填写“最终作者主体”和“最终系列”。"],
  ["4", "复合标题若包含多人，选择“多作者拆分”，并在备注写清拆分方式。"],
  ["5", "非计划内容选择“忽略”，避免后续被自动创建为计划。"],
];
guideSheet.getRange("A12:F12").merge();
guideSheet.getRange("A12").values = [["填写示例"]];
guideSheet.getRange("A14:F18").values = [
  ["原始名称", "处理结果", "最终作者主体", "最终系列", "拆分多作者", "备注"],
  ["扫地僧早场", "确认建议", "扫地僧", "早场", "否", ""],
  ["扫地僧，辉哥中赔", "多作者拆分", "", "", "是", "扫地僧；辉哥|中赔"],
  ["彩虹抄底3.0", "修改", "彩虹", "抄底3.0", "否", ""],
  ["昨日赛果", "忽略", "", "", "否", "不创建计划"],
];
guideSheet.getRange("A20:F20").merge();
guideSheet.getRange("A20").values = [[
  "注意：只需标注不确定或需要修改的项目；完全认可建议时，选择“确认建议”即可。",
]];

guideSheet.getRange("A1:F1").format = {
  fill: green,
  font: { name: "PingFang SC", bold: true, color: white, size: 18 },
  verticalAlignment: "center",
};
guideSheet.getRange("A3:F3").format = {
  fill: greenSoft,
  font: { name: "PingFang SC", color: greenDark, size: 11 },
  wrapText: true,
  verticalAlignment: "center",
};
guideSheet.getRange("A5:B5").format = {
  fill: greenDark,
  font: { name: "PingFang SC", bold: true, color: white },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
guideSheet.getRange("A6:B10").format = {
  font: { name: "PingFang SC", color: ink, size: 10 },
  wrapText: true,
  verticalAlignment: "center",
  borders: {
    insideHorizontal: { style: "thin", color: "#E5EBE8" },
    bottom: { style: "thin", color: line },
  },
};
guideSheet.getRange("A12:F12").format = {
  fill: greenSoft,
  font: { name: "PingFang SC", bold: true, color: greenDark, size: 12 },
  verticalAlignment: "center",
};
guideSheet.getRange("A14:F14").format = {
  fill: greenDark,
  font: { name: "PingFang SC", bold: true, color: white, size: 10 },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
guideSheet.getRange("A15:F18").format = {
  font: { name: "PingFang SC", color: ink, size: 10 },
  wrapText: true,
  verticalAlignment: "center",
  borders: {
    insideHorizontal: { style: "thin", color: "#E5EBE8" },
    bottom: { style: "thin", color: line },
  },
};
guideSheet.getRange("A20:F20").format = {
  fill: editable,
  font: { name: "PingFang SC", bold: true, color: "#755E00", size: 10 },
  wrapText: true,
  verticalAlignment: "center",
};
const guideWidths = [22, 48, 24, 22, 16, 34];
for (let index = 0; index < guideWidths.length; index += 1) {
  guideSheet.getRangeByIndexes(0, index, 22, 1).format.columnWidth =
    guideWidths[index];
}
guideSheet.getRange("1:1").format.rowHeight = 34;
guideSheet.getRange("3:3").format.rowHeight = 36;
guideSheet.getRange("5:5").format.rowHeight = 28;
guideSheet.getRange("6:10").format.rowHeight = 36;
guideSheet.getRange("12:12").format.rowHeight = 28;
guideSheet.getRange("14:14").format.rowHeight = 30;
guideSheet.getRange("15:18").format.rowHeight = 34;
guideSheet.getRange("20:20").format.rowHeight = 36;
guideSheet.freezePanes.freezeRows(3);

const summary = await workbook.inspect({
  kind: "table",
  range: "分类标注!A1:K15",
  include: "values,formulas",
  tableMaxRows: 15,
  tableMaxCols: 11,
  maxChars: 9000,
});
console.log("ANNOTATION_CHECK");
console.log(summary.ndjson);

const seriesCheck = await workbook.inspect({
  kind: "table",
  range: "系列词确认!A1:E15",
  include: "values,formulas",
  tableMaxRows: 15,
  tableMaxCols: 5,
  maxChars: 7000,
});
console.log("SERIES_CHECK");
console.log(seriesCheck.ndjson);

const errors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 300 },
  summary: "final formula error scan",
});
console.log("ERROR_SCAN");
console.log(errors.ndjson);

const previews = [
  ["分类标注", "A1:K28", "preview_classification.png"],
  ["系列词确认", `A1:E${seriesEndRow}`, "preview_series.png"],
  ["填写说明", "A1:F20", "preview_guide.png"],
];
for (const [sheetName, range, fileName] of previews) {
  const blob = await workbook.render({
    sheetName,
    range,
    scale: 1.3,
    format: "png",
  });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  await fs.writeFile(`${outputDir}/${fileName}`, bytes);
}

await fs.mkdir(outputDir, { recursive: true });
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(`${outputDir}/计划名称分类标注表_2026-07-27.xlsx`);

console.log(
  JSON.stringify({
    classificationRows: classificationRows.length,
    seriesRows: seriesRows.length,
    output: `${outputDir}/计划名称分类标注表_2026-07-27.xlsx`,
  }),
);
