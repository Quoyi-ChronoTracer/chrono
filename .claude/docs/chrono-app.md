# chrono-app
React 19 + TypeScript frontend. Legal timeline analysis UI.

## Commands
```bash
yarn start              # dev server
yarn build
yarn test --run         # CI mode (watch: yarn test, coverage: yarn test:coverage)
yarn lint && yarn lint:fix
```
Always run `yarn test --run` and `yarn lint` before a task is complete.

## Key Patterns
- **State**: Entire app state lives in `src/contexts/MatterContext/` via React Context + useReducer. Shape defined by io-ts codecs in `src/types/MatterState.ts`. Persisted to localStorage.
- **API**: All backend calls go through `src/api/client.ts`. Responses validated at runtime via `decodeType()` — never bypass this layer.
- **Error handling**: fp-ts `Either` / `pipe` throughout the API layer. Never use `any`.
- **Tests**: Co-located with source as `Component.test.tsx`. Vitest + Testing Library.

## References
- Dependencies & scripts → `package.json`
- Env vars → `src/utils/env.ts` and `.env`
- API types & codecs → `src/api/types.ts`
- View models per event/device type → `src/api/viewModels/`
- Routes → `src/main.tsx` or router file
