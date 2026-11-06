# Events.tres: one Array[EventData] that EventSystem.gd sorts into buckets at _ready(). An
# EventData.function EventSystem does not define resolves to a Callable that does nothing.

const _EVENTS_PATH := "res://Events/Events.tres"

func _events_resource() -> Resource:
	return _registry_resource(_EVENTS_PATH, "events")

# Not name or type: too many other Resource classes carry those.
func _looks_like_event_data(res: Variant) -> bool:
	return res is Resource and _has_properties(res, ["function", "possibility", "day"])
