import REPL
using REPL.TerminalMenus
using Dates
using DelimitedFiles
using Terming
include(joinpath(@__DIR__, "readline_default.jl"))

get_tag(id) = get(tags, id, nothing)
has_tag(id) = haskey(tags, id)

tags_file = joinpath(@__DIR__, ".track_data/tags.txt")
if !isfile(tags_file)
    mkpath(dirname(tags_file))
    writedlm(tags_file, ["id" "tag"], "\t")
end

to_dict(a) = Dict((a[:, 1] .=> a[:, 2])...)
tags =  try 
    readdlm(tags_file, '\t') |> to_dict
catch
    Dict()
end

function process_name(name)
    id = extract_id(name)
    result = haskey(tags, id) ? name * " | " * tags[id] : name
    if length(result) > Terming.displaysize()[2]-3
        result = result[1:nextind(result, Terming.displaysize()[2]-6)] * "..."
    end
    return result
end
revert_name(name) = split(name, " | ") |> first

function add_tag!(id, tag)
    if isempty(tag)
        delete!(tags, id)
    else
        tags[id] = tag
    end
    writedlm(tags_file, [collect(keys(tags)) collect(values(tags))])
end

function extract_id(slurm)
    id = match(r"slurm-(\d+)\.out", slurm)
    if !isnothing(id)
        id = parse(Int32, id[1])
    end
    return id
end

tagline_command = "ADDTAG:"

extract_tag_line(line) = split(line, tagline_command) |> last |> chomp


function stream_slurm(slurm, id, com_channel)
    open(slurm) do io
        lines = readlines(io, keep=true)
        print.(lines)

        if !has_tag(id)
            tag_line = findfirst(occursin.(tagline_command, lines))
            if !isnothing(tag_line)
                tag = extract_tag_line(lines[tag_line])
                add_tag!(id, tag)
            end
        end

        quit = false
        while !quit
            if !eof(io) 
                line = readline(io; keep=true)
                print(line)
                if occursin(tagline_command, line) && !has_tag(id)
                    tag = extract_tag_line(lines[tag_line])
                    add_tag!(id, tag)
                end
            end
            yield() 
            sleep(0.02)
            if isready(com_channel)
                message = take!(com_channel)
                if message == :quit
                    quit = true
                elseif message == :pause
                    while take!(com_channel) ≠ :resume
                        sleep(0.02)
                    end
                end
            end
        end
    end
end

function process_line(line, output_lines=[[]], cursor=[1,1])
    function push_char!(c)
        if cursor[2] > length(output_lines[cursor[1]])
            push!(output_lines[cursor[1]], c)
        else
            output_lines[cursor[1]][cursor[2]] = c
        end
        cursor += [0, 1]
    end
    return_cursor() = (cursor[2] = 1; cursor)
    function push_line!()
        push!(output_lines, [])
        cursor += [1, 0]
        return_cursor()
    end
    j = 1
    indices = eachindex(line) |> collect
    while j ≤ length(indices)
        c = line[indices[j]]
        if c == '\r'
            return_cursor()
        elseif c == '\n'
            push_line!()
        elseif c == '\u1b'
            if line[indices[j+2]] == 'A'
                cursor = max.([1, 1], cursor - [1, 0])
            elseif line[indices[j+2]] == 'K' && length(output_lines[cursor[1]]) > 0
                output_lines[cursor[1]] = output_lines[cursor[1]][1:max(1, cursor[2]-1)]
            end
            j += 2
        else
            push_char!(c)
        end
        j += 1
    end
    # push_line!()
    return output_lines, cursor
end

function process_lines(lines, output_lines=[[]], cursor=[1,1])
    for line ∈ lines
        output_lines, cursor = process_line(line, output_lines, cursor)
    end
    return output_lines, cursor
end

lines_to_string(full_lines) = strip(join(join.(full_lines), '\n'), [' ', '\n'])

function parent(path::String)
    path[end] == '/' ? dirname(path[1:end-1]) : dirname(path)
end

function save_slurm(slurm)
    println("Saving processed slurm...")
    output_dir, output_name = splitdir(slurm)
    # output_name = replace(output_name, r"\.out" => s"_processed.out")
    output_path = joinpath(parent(output_dir), "processed_slurms", output_name)
    mkpath(dirname(output_path))
    writeoutput(str) = open(output_path, "w") do io
        print(io, str)
    end
    lines = readlines(slurm, keep=true)
    full_lines, _ = process_lines(lines)
    writeoutput(lines_to_string(full_lines))
    
    println("Saved processed slurm!")
end

function edit_tag(id; use_raw=false)
    if use_raw
        Terming.raw!(true)
    end
    println("Enter a new tag for this file:")
    tag = readline_default(has_tag(id) ? get_tag(id) : "")
    add_tag!(id, tag)
    if use_raw
        Terming.raw!(false)
    end
end

function interactive_slurm_stream(slurm)
    id = extract_id(slurm)
    com_channel = Channel(10)
    @async stream_slurm(slurm, id, com_channel)
    Terming.raw!(true)
    key = nothing
    while key ∉ [Terming.ESC, 'q']
        key = get_key_press().key
        if key == 'c'
            println("Cancelling...")
            run(`scancel $id`)
        elseif key == 't'
            put!(com_channel, :pause)
            edit_tag(id)
            println("Resuming...")
            put!(com_channel, :resume)
        elseif key == 's'
            save_slurm(slurm)
        end
    end
    push!(com_channel, :quit)
    println("Quitting...") 
    # disable raw mode
    Terming.raw!(false)
end

function parent(path::String)
    path[end] == '/' ? dirname(path[1:end-1]) : dirname(path)
end

function sh_file_menu(dir)
    options = ["Back...", filter(x->endswith(x, ".sh"), readdir(dir))...]
    menu = RadioMenu(options, pagesize=10)
    choice = request("Choose a script to run:", menu)

    if choice > 2
        file = options[choice]
        println("Running ", file)
        if startswith(file, "srun_")
            run(`sbatch $(options[choice])`)
        else
            run(`./$(options[choice])`)
        end
    end
    return
end

function slurm_menu(slurm)
    
    id = extract_id(slurm)
    options = ["Read", "Save processed", "Cancel job", "Edit tag", "Back"]

    menu = RadioMenu(options, pagesize=10)

    
    # run(`squeue -u $(ENV["USER"])`)
    choice = request("Choose option for $(extract_id(slurm)):", menu)

    if choice == 1
        println("Showing ", extract_id(slurm))
        interactive_slurm_stream(slurm)
    elseif choice == 2
        save_slurm(slurm)
    elseif choice == 3
        run(`scancel $id`)
    elseif choice == 4
        edit_tag(id; use_raw=true)
    else
        println("Returning...")
    end
end

function main(base_dir="./slurms")
    while true
        cd(@__DIR__)
        options = ["Refresh", "Run script", reverse(process_name.(readdir(base_dir)))...]

        menu = RadioMenu(options, pagesize=10)

        
        run(`squeue -u $(ENV["USER"])`)
        choice = request("Choose option:", menu)

        if choice > 2
            println("Opening ", options[choice])
            # interactive_slurm_stream(joinpath(base_dir, revert_name(options[choice])))
            slurm_menu(joinpath(base_dir, revert_name(options[choice])))
        elseif choice == 2
            sh_file_menu(".")
        elseif choice == 1
            println("Refreshing...")
            println()
        else
            println("Menu canceled.")
            exit()
        end
    end
end

main()