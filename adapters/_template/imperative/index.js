export const capabilities = {
  "grades.list": async (ctx, params) => {
    const res = await ctx.fetch("https://jw.example.edu.cn/api/grades?term=" + params.term);
    const json = await res.json();
    return {
      term: params.term,
      // 校本绩点尺度（ADR-001 §3.5）：本体据此判断能否聚合 GPA。不知道就别猜，
      // 省略即可——本体会 fail-closed 不展示 GPA，好过展示一个满分档不明的数。
      gradePointScale: "4.0",
      items: json.list.map((item) => {
        const normalized = {
          courseId: item.id,
          courseName: item.name,
          credit: item.credit,
          score: {
            kind: "numeric",
            value: item.score,
            max: 100,
          },
          category: item.type === "必修" ? "required" : item.type === "选修" ? "elective" : "unknown",
          status: "final",
        };
        // 分数→绩点的换算是校本派生，归 adapter（ADR-001 §3.5）。来源直接给出时
        // 标 "source"；若本 adapter 按学校换算表自行推算，改标 "adapter-derived"。
        if (item.gpa !== undefined && item.gpa !== null) {
          normalized.gradePoint = item.gpa;
          normalized.gradePointSource = "source";
        }
        return normalized;
      }),
    };
  },

  "schedule.week": async (ctx, params) => {
    const res = await ctx.fetch("https://jw.example.edu.cn/api/schedule?week=" + params.week);
    const json = await res.json();
    return {
      term: params.term,
      week: params.week,
      days: json.days.map((day) => ({
        dayOfWeek: day.index,
        slots: day.courses.map((c) => ({
          start: c.start,
          end: c.end,
          courseName: c.name,
          courseId: c.id,
          teacher: c.teacher,
          location: c.room,
          weeks: c.weeks,
        })),
      })),
    };
  },
};
