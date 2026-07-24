export const capabilities = {
  "grades.list": (ctx, params, responses) => {
    const json = JSON.parse(responses.raw.body);
    return {
      term: params.term,
      items: json.list.map((item) => ({
        courseId: item.id,
        courseName: item.name,
        credit: item.credit,
        score: {
          kind: "numeric",
          value: item.score,
          max: 100,
        },
        gradePoint: item.gpa ?? null,
        category: item.type === "必修" ? "required" : "elective",
        status: "final",
      })),
    };
  },
};
