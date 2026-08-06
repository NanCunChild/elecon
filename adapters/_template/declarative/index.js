export const capabilities = {
  "grades.list": (ctx, params, responses) => {
    const json = JSON.parse(responses.raw.body);
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
};
