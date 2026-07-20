export const capabilities = {
  "app.announcement": (ctx) => {
    ctx.log("info", "HelloWorld");
    return {
      version: "helloworld-0.1.0",
      items: [
        {
          title: "HelloWorld",
          content: "HelloWorld",
          publishedAt: new Date(ctx.now()).toISOString(),
        },
      ],
    };
  },
};
