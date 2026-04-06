export const Platform = {
  OS: 'ios',
  select<T>(options: { ios?: T; android?: T; default?: T }) {
    if (options.ios !== undefined) {
      return options.ios;
    }
    return options.default;
  },
};
