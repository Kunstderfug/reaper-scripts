//! Bounded source workers; results always return in original input order.
use std::sync::atomic::{AtomicUsize, Ordering};

pub fn default_threads() -> usize {
    available_threads().min(8)
}

fn available_threads() -> usize {
    std::thread::available_parallelism().map_or(1, usize::from)
}

pub fn worker_count(requested: usize, jobs: usize) -> usize {
    requested.max(1).min(available_threads()).min(jobs)
}

pub fn map<T: Sync, R: Send, F: Fn(&T) -> R + Sync>(
    jobs: &[T],
    requested: usize,
    operation: F,
) -> Result<Vec<R>, String> {
    let workers = worker_count(requested, jobs.len());
    if workers <= 1 {
        return Ok(jobs.iter().map(operation).collect());
    }
    let next = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(workers);
        for _ in 0..workers {
            let operation = &operation;
            let next = &next;
            handles.push(scope.spawn(move || {
                let mut results = Vec::new();
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(job) = jobs.get(index) else { break };
                    results.push((index, operation(job)));
                }
                results
            }));
        }
        let mut results = Vec::with_capacity(jobs.len());
        let mut panicked = false;
        for handle in handles {
            match handle.join() {
                Ok(chunk) => results.extend(chunk),
                Err(_) => panicked = true,
            }
        }
        if panicked {
            return Err("A MIDI source worker panicked; no output was written".into());
        }
        results.sort_unstable_by_key(|(index, _)| *index);
        Ok(results.into_iter().map(|(_, result)| result).collect())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn joins_workers_and_returns_an_error_on_panic() {
        if worker_count(2, 4) < 2 {
            return;
        }
        let completed = AtomicUsize::new(0);
        let result = map(&[0, 1, 2, 3], 2, |&index| {
            if index == 3 {
                panic!("injected worker failure");
            }
            completed.fetch_add(1, Ordering::Relaxed);
            index
        });
        assert!(result.unwrap_err().contains("no output was written"));
        assert_eq!(completed.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn preserves_order_and_bounds_workers() {
        let jobs: Vec<_> = (0..200).collect();
        assert_eq!(
            map(&jobs, 1, |n| n * n).unwrap(),
            map(&jobs, 8, |n| n * n).unwrap()
        );
        assert!(worker_count(usize::MAX, 2) <= 2);
        assert_eq!(worker_count(1, 200), 1);
        assert!(map::<u8, u8, _>(&[], 8, |n| *n).unwrap().is_empty());
    }
}
