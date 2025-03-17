using Terming

clear_rest_line(stream::IO) = print(stream, "\u1b[K")
clear_rest_line() = print("\u1b[K")

get_key_press() = Terming.parse_sequence(Terming.read_stream())

function readline_default(default)
    result = collect(default)
    cur = length(result) + 1
    print(default)
    event = get_key_press()

    function update_end()
        Terming.buffered() do buffer
            csave(buffer)
            Terming.print(buffer, String(result[cur:end])*" ")
            clear_rest_line(buffer)
            crestore(buffer)
        end
    end

    function delete()
        cur == length(result) + 1 && return
        deleteat!(result, cur)
        update_end()
    end

    function process_key(key::Char)
        insert!(result, cur, key)
        print(key)
        cur += 1
        update_end()
        return result
    end
    function move_left()
        if cur > 1
            cmove_left()
            cur -= 1
            if rem(cur, Terming.displaysize()[2])==0
                Terming.buffered() do buffer
                    cmove_line_up(buffer)
                    cmove_right(buffer, Terming.displaysize()[2])
                end
            end
        end
    end
    function move_up()
        if cur > Terming.displaysize()[2]
            cmove_up()
            cur -= Terming.displaysize()[2]
        end
    end
    function move_down()
        if cur < length(result) - Terming.displaysize()[2]+2
            cmove_down()
            cur += min(Terming.displaysize()[2], length(result)-cur+1)
        end
    end
    function move_right()
        if cur < length(result) + 1
            cmove_right()
            cur += 1
            if cur ≤ length(result)+1 && rem(cur-1, Terming.displaysize()[2])==0
                cmove_line_down()
            end
        end
    end

    function process_key(key)
        if key == Terming.LEFT
            move_left()
        elseif key == Terming.RIGHT
            move_right()
        elseif key == Terming.UP
            move_up()
        elseif key == Terming.DOWN
            move_down()
        elseif key == Terming.BACKSPACE
            if cur > 1
                move_left()
                delete()
            end
        elseif key == Terming.DELETE
            delete()
        end
        return result
    end
    process_event(event::Terming.KeyPressedEvent) = process_key(event.key)
    function process_event(event::Terming.PasteEvent)
        print(event.content)
        return vcat(result[1:cur-1], Vector{Char}(event.content), result[cur:end])
    end

    while !isa(event, Terming.KeyPressedEvent) || event.key ≠ Terming.ENTER
        result = process_event(event)
        event = get_key_press()
    end
    cmove_line_down((length(result)-cur)÷Terming.displaysize()[2])
    println()
    return String(result)
end