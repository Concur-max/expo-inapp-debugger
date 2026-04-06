module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/__tests__'],
  transform: {
    '^.+\\.(ts|tsx)$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.json' }],
  },
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json'],
  testPathIgnorePatterns: ['/node_modules/', '/__tests__/__mocks__/'],
  moduleNameMapper: {
    '^react-native$': '<rootDir>/__tests__/__mocks__/react-native.ts',
  },
  collectCoverageFrom: ['src/internal/**/*.ts'],
};
