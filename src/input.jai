Button_State :: struct
{
	is_down: bool;
	was_down: bool;
	ended_down: bool;
	pressed: bool;
	up: bool;
	half_transitions: s32;
}

Controller_Input :: struct
{
	keys: Table(SDL_Scancode, Button_State);
}

Input :: struct
{
	keyboard: Controller_Input;
}

global_input: Input;

process_keypress :: (new_state: *Button_State, is_down: bool, was_down: bool)
{
	new_state.is_down = is_down;
	new_state.ended_down = is_down;
	new_state.up = was_down;
	new_state.was_down = was_down;
	new_state.half_transitions += 1;
}

reset_controller_input :: (input: *Controller_Input)
{
	for *input.keys
	{
		it.ended_down = false;
		it.was_down = false;
	}
}

key_down :: (key: SDL_Scancode) -> bool
{
	using global_input;
	button_state := table_find_pointer(*keyboard.keys, key);
	if button_state
	{
		return button_state.is_down;
	}
	else
	{
		return false;
	}
}

key_ended_down :: (key: SDL_Scancode) -> bool
{
	using global_input;
	button_state := table_find_pointer(*keyboard.keys, key);
	if button_state
	{
		return button_state.ended_down;
	}
	else
	{
		return false;
	}
}