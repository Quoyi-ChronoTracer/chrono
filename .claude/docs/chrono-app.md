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
- **State**: Entire app state lives in `src/contexts/MatterContext/` via React Context + useReducer. Shape defined by io-ts codecs in `src/types/MatterState.ts`. Persisted to localStorage. Components never call the API directly — every fetch and mutation flows through a MatterContext dispatcher method. If the action type you need doesn't exist, add it to the reducer.
- **API**: All backend calls go through `src/api/client.ts`. Responses validated at runtime via `decodeType()` — never bypass this layer. When a new field arrives from the backend, add it to the io-ts codec before using it. Never cast or assert API data.
- **Async data**: All async state uses `PayloadState<T>` (`{ loading, payload, error }`). Paginated data uses `PagePayloadState`. Don't invent new loading patterns.
- **View models**: Display metadata (icons, colors, labels, participation types) lives in `src/api/viewModels/` via `getEventTypeViewModel()`. Never hardcode display logic in components.
- **Error handling**: fp-ts `Either` / `pipe` throughout the API layer. Never use `any`.
- **Exports**: Named exports everywhere. Default exports reserved for `App`, the theme, and page-level route components.
- **Styling**: Use `theme.*` values from `src/theme/` — never hardcode spacing, colors, font sizes, or z-index. If a value doesn't exist in the theme and is needed in more than one place, extend the theme.
- **Layout**: Changes to layout components ripple. Always consider interactions with TopNav, the AI overlay panel, dialogs, and the sidebar. Check z-index layering when adding overlapping elements.
- **Tests**: Co-located with source as `Component.test.tsx`. Vitest + Testing Library.

## References
- Dependencies & scripts → `package.json`
- Env vars → `src/utils/env.ts` and `.env`
- API types & codecs → `src/api/types.ts`
- View models per event/device type → `src/api/viewModels/`
- Routes → `src/main.tsx` or router file
