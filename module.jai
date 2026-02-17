/*

usage:

main :: () {

    // why is it on the heap? 
    // because the frame proflier allocates a bunch of storage for its fixed size pools and stuff
    // and it probably won't fit on the stack, on windows it doesn't by default, that's the only reason.

    fp := New(Frame_Profiler);
    defer free(fp);

    init_frame_profiler(fp, target_hz = 1000);  // 1ms target so tiny sleeps register as "slow"
    
    for frame: 0..99 {
        start_frame(fp);
        
            start_section(*fp.section_timer, "update");
                start_section(*fp.section_timer, "physics");
                sleep_milliseconds(0);
                end_section(*fp.section_timer, "physics");
                
                start_section(*fp.section_timer, "ai");
                sleep_milliseconds(0);
                end_section(*fp.section_timer, "ai");
            end_section(*fp.section_timer, "update");
            
            start_section(*fp.section_timer, "render");
            // simulate occasional spike
            if frame % 20 == 10 then sleep_milliseconds(5);
            else sleep_milliseconds(0);
            end_section(*fp.section_timer, "render");
        
        end_frame(fp);
    }
    
    print_profiler_summary(fp);
}

*/

#import "Basic";
#import "Math";
#import "tbx/time";

MAX_SLOW_FRAMES :: 128;

Slow_Frame :: struct {
    root:              *Timed_Section;
    frame_number:      u64;
    time_since_start:  float;
    elapsed:           float;
    overshoot_ratio:   float;
}

Section_Comparison :: struct {
    name:          string;
    slow_elapsed:  float;
    avg_elapsed:   float;
    delta:         float;   // slow - avg
    ratio:         float;   // slow / avg
    
    children:    [MAX_CHILDREN] *Section_Comparison;
    child_count: u32;
}

Frame_Comparison_Result :: struct {
    root:            *Section_Comparison;
    pool:            Fixed_Pool(Section_Comparison, MAX_SECTIONS);
    slow_frame:      *Slow_Frame;
    frame_number:    u64;
    overshoot_ratio: float;
}

Frame_Profiler :: struct {
    section_timer: Section_Timer;

    target_frame_rate_hz: u32   = 60;
    target_frame_period:  float = 1.0 / 60.0;

    // Circular buffer of captured slow frames.
    // captured_slow_frame_pools[i] owns all the nodes for captured_slow_frames[i].root.
    // They are paired by physical index, same pattern as completed_tree_roots/pools
    // in Section_Timer.
    captured_slow_frames:      [MAX_SLOW_FRAMES] Slow_Frame;
    captured_slow_frame_pools: [MAX_SLOW_FRAMES] Fixed_Pool(Timed_Section, MAX_SECTIONS);
    captured_slow_frame_count: u32;
    captured_slow_frame_write_index: u32;

    program_start_time: Apollo_Time;
    total_frame_count:  u64;
}


init_frame_profiler :: (using fp: *Frame_Profiler, target_hz: u32 = 60) {
    init_section_timer(*section_timer);
    target_frame_rate_hz = target_hz;
    target_frame_period  = 1.0 / cast(float) target_hz;
    captured_slow_frame_count       = 0;
    captured_slow_frame_write_index = 0;
    program_start_time   = current_time_monotonic();
    total_frame_count    = 0;
}

start_frame :: (using fp: *Frame_Profiler) {
    start_section(*section_timer, "frame");
}

end_frame :: (using fp: *Frame_Profiler) {
    end_section(*section_timer, "frame");

    // end_section with stack_depth hitting 0 triggers
    // save_current_root_section_to_history, which increments
    // completed_tree_write_index after saving. So the latest entry sits
    // one slot behind the current index.
    latest_idx := (section_timer.completed_tree_write_index - 1 + MAX_HISTORY) % MAX_HISTORY;
    latest_root := section_timer.completed_tree_roots[latest_idx];

    if latest_root != null && latest_root.completed {
        elapsed := latest_root.elapsed_seconds;
        if elapsed > target_frame_period {
            capture_slow_frame(fp, latest_root, elapsed);
        }
    }

    total_frame_count += 1;
}

capture_slow_frame :: (using fp: *Frame_Profiler, root: *Timed_Section, elapsed: float) {
    dest_pool := *captured_slow_frame_pools[captured_slow_frame_write_index];
    pool_reset(dest_pool);
    copy_section_tree(root, dest_pool);

    sf := *captured_slow_frames[captured_slow_frame_write_index];
    sf.root             = pool_get(dest_pool, 0);
    sf.frame_number     = total_frame_count;
    sf.time_since_start = cast(float) to_float64_seconds(current_time_monotonic() - program_start_time);
    sf.elapsed          = elapsed;
    sf.overshoot_ratio  = elapsed / target_frame_period;

    captured_slow_frame_write_index = (captured_slow_frame_write_index + 1) % MAX_SLOW_FRAMES;
    if captured_slow_frame_count < MAX_SLOW_FRAMES {
        captured_slow_frame_count += 1;
    }
}

get_slow_frame :: (using fp: *Frame_Profiler, index: u32) -> *Slow_Frame {
    if index >= captured_slow_frame_count return null;

    // oldest entry lives at captured_slow_frame_write_index when the buffer has wrapped,
    // otherwise at 0.
    actual: u32;
    if captured_slow_frame_count < MAX_SLOW_FRAMES {
        actual = index;
    } else {
        actual = (captured_slow_frame_write_index + index) % MAX_SLOW_FRAMES;
    }
    return *captured_slow_frames[actual];
}


compare_slow_frame_to_average :: (
    fp: *Frame_Profiler,
    slow_idx: u32,
    result: *Frame_Comparison_Result
) {
    pool_reset(*result.pool);
    result.root = null;

    sf := get_slow_frame(fp, slow_idx);
    if sf == null return;

    result.slow_frame      = sf;
    result.frame_number    = sf.frame_number;
    result.overshoot_ratio = sf.overshoot_ratio;

    averaged: Averaged_Section_Result;
    get_averaged_sections(*fp.section_timer, *averaged);

    if averaged.root == null || sf.root == null return;

    result.root = build_comparison_recursive(*result.pool, sf.root, averaged.root);
}

build_comparison_recursive :: (
    pool: *Fixed_Pool(Section_Comparison, MAX_SECTIONS),
    slow: *Timed_Section,
    avg:  *Averaged_Section
) -> *Section_Comparison {
    if slow == null return null;

    dest := pool_acquire(pool);
    dest.name         = slow.name;
    dest.slow_elapsed = slow.elapsed_seconds;
    dest.avg_elapsed  = ifx avg != null then avg.average_elapsed else 0.0;
    dest.delta        = dest.slow_elapsed - dest.avg_elapsed;
    dest.ratio        = ifx dest.avg_elapsed > 0.0 then dest.slow_elapsed / dest.avg_elapsed else 0.0;
    dest.child_count  = slow.child_count;

    for i: 0..MAX_CHILDREN-1 {
        dest.children[i] = null;
    }

    for i: 0..cast(s64) slow.child_count - 1 {
        if slow.children[i] == null continue;

        avg_child: *Averaged_Section = null;
        if avg != null && cast(u32)i < avg.child_count {
            avg_child = avg.children[i];
        }
        dest.children[i] = build_comparison_recursive(pool, slow.children[i], avg_child);
    }

    return dest;
}


print_slow_frame :: (sf: *Slow_Frame, total_program_duration: float = 0.0, indent: u32 = 0) {
    if sf == null { print("(null slow frame)\n"); return; }

    print("Slow frame (frame #%) | %ms (%x target) | %s into program",
          sf.frame_number,
          formatFloat(sf.elapsed * 1000, trailing_width=3, zero_removal=.NO),
          formatFloat(sf.overshoot_ratio, trailing_width=1, zero_removal=.NO),
          formatFloat(sf.time_since_start, trailing_width=2, zero_removal=.NO));

    if total_program_duration > 0.0 {
        pct := (sf.time_since_start / total_program_duration) * 100.0;
        print(" (%\% through)", formatFloat(pct, trailing_width=1, zero_removal=.NO));
    }

    print("\n");

    if sf.root != null {
        print_timed_section_tree(sf.root, indent + 1);
    }
}

print_timed_section_tree :: (section: *Timed_Section, indent: u32 = 0) {
    if section == null return;

    for i: 0..cast(s64) indent - 1  print("  ");
    print("%: %ms\n",
          section.name,
          formatFloat(section.elapsed_seconds * 1000, trailing_width=3, zero_removal=.NO));

    for i: 0..cast(s64) section.child_count - 1 {
        if section.children[i] != null {
            print_timed_section_tree(section.children[i], indent + 1);
        }
    }
}

print_frame_comparison :: (comp: *Section_Comparison, target_period: float, indent: u32 = 0) {
    if comp == null return;

    for i: 0..cast(s64) indent - 1  print("  ");

    print("%: slow=%ms  avg=%ms",
          comp.name,
          formatFloat(comp.slow_elapsed * 1000, trailing_width=3, zero_removal=.NO),
          formatFloat(comp.avg_elapsed  * 1000, trailing_width=3, zero_removal=.NO));

    if comp.delta >= 0 {
        print("  delta=+%ms", formatFloat(comp.delta * 1000, trailing_width=3, zero_removal=.NO));
    } else {
        print("  delta=%ms", formatFloat(comp.delta * 1000, trailing_width=3, zero_removal=.NO));
    }

    if comp.ratio > 0.0 {
        print("  (%x avg)", formatFloat(comp.ratio, trailing_width=1, zero_removal=.NO));
    }
    print("\n");

    for i: 0..cast(s64) comp.child_count - 1 {
        if comp.children[i] != null {
            print_frame_comparison(comp.children[i], target_period, indent + 1);
        }
    }
}

print_profiler_summary :: (fp: *Frame_Profiler) {
    print("===== Frame Profiler Summary =====\n");
    print("Target: % Hz (%ms per frame)\n",
          fp.target_frame_rate_hz,
          formatFloat(fp.target_frame_period * 1000, trailing_width=3, zero_removal=.NO));
    print("Total frames: %\n", fp.total_frame_count);
    print("Slow frames captured: %\n", fp.captured_slow_frame_count);

    // average frame time from section timer history
    averaged: Averaged_Section_Result;
    get_averaged_sections(*fp.section_timer, *averaged);

    if averaged.root != null {
        avg_ms := averaged.root.average_elapsed * 1000;
        target_ms := fp.target_frame_period * 1000;
        over := avg_ms - target_ms;

        print("\nAverage frame: %ms", formatFloat(avg_ms, trailing_width=3, zero_removal=.NO));
        if over > 0 {
            print("  (+%ms over target)", formatFloat(over, trailing_width=3, zero_removal=.NO));
        } else {
            print("  (%ms under target)", formatFloat(-over, trailing_width=3, zero_removal=.NO));
        }
        print("\n");

        print("\nAveraged section breakdown:\n");
        print_averaged_section(averaged.root, indent = 1);
    }

    if fp.captured_slow_frame_count > 0 {
        print("\n--- Slow Frames ---\n\n");

        total_program_duration := cast(float) to_float64_seconds(current_time_monotonic() - fp.program_start_time);

        for i: 0..cast(s64) fp.captured_slow_frame_count - 1 {
            sf := get_slow_frame(fp, cast(u32) i);
            print_slow_frame(sf, total_program_duration);

            comp: Frame_Comparison_Result;
            compare_slow_frame_to_average(fp, cast(u32) i, *comp);
            if comp.root != null {
                print("  Comparison vs average:\n");
                print_frame_comparison(comp.root, fp.target_frame_period, indent = 2);
            }
            print("\n");
        }
    }

    print("==================================\n");
}
