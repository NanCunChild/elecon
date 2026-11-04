import type { QueryControls, QueryControlsParams, ClassroomAvailableParams } from '../types.js';

// School field ids are ordinary data; no fixed host parameter is implied.
export function describeQuery(params: QueryControlsParams): QueryControls {
  return {
    target: params.target,
    title: 'Synthetic query',
    submitLabel: 'Apply',
    controls: [
      { id: 'northCampusRoomKind', kind: 'select', label: 'Type', options: [{ value: 'seminar', label: 'Seminar' }] },
      { id: 'minimumSeats', kind: 'number', label: 'Seats', minimum: 0, integer: true, initialValue: 0 },
      { id: 'projector', kind: 'boolean', label: 'Projector', initialValue: false },
      { id: 'features', kind: 'multiSelect', label: 'Features', initialValue: ['quiet'], options: [{ value: 'quiet', label: 'Quiet' }] },
      { id: 'visitWindow', kind: 'timeRange', label: 'Time', timeZone: 'Asia/Shanghai', initialValue: { start: '09:00', end: '10:00' } },
    ],
  };
}
export const query: ClassroomAvailableParams = {
  filters: { minimumSeats: 0, projector: false, features: ['quiet'], visitWindow: { start: '09:00', end: '10:00' } },
};
