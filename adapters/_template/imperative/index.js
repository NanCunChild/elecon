export const capabilities = {
  "grades.list": async (ctx, params) => {
    const res = await ctx.fetch("https://jw.example.edu.cn/api/grades?term=" + params.term);
    const json = await res.json();
    return {
      term: params.term,
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
        if (item.gpa !== undefined && item.gpa !== null) normalized.gradePoint = item.gpa;
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
