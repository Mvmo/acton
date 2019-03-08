/*
 * A concurrent, scalable, wait-free task pool implementation that performs well under high CAS contention
 *
 * This file contains functions related to managing lists of tree pools
 *
 *  Created on: 22 Jan 2019
 *      Author: aagapi
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>
#include <string.h>

#include "concurrent_task_pool.h"

concurrent_pool_node * allocate_pool_node(int node_id, int tree_height, int * precomputed_level_sizes)
{
	concurrent_pool_node * pn = NULL;
	concurrent_tree_pool_node * tree_pool = allocate_tree_pool(tree_height, precomputed_level_sizes);

	if(tree_pool == NULL)
		return NULL;

	pn = (concurrent_pool_node *) malloc(sizeof(struct concurrent_pool_node));

	if(pn != NULL)
	{
		pn->node_id = node_id;
		pn->tree = tree_pool;
		atomic_init(&pn->next, NULL);
	}
	else
	{
		free_tree_pool(tree_pool);
	}

	return pn;
}

void free_pool_node(concurrent_pool_node * p)
{
	free_tree_pool(p->tree);
	free(p);
}

concurrent_pool * _allocate_pool(int tree_height, int k_no_trials)
{
	concurrent_pool * p = (concurrent_pool *) malloc(sizeof(struct concurrent_pool));

	if(p == NULL)
	{
		return NULL;
	}

	memset(p, 0, sizeof(struct concurrent_pool));

#ifdef PRECALCULATE_TREE_LEVEL_SIZES
	p->level_sizes = (int *) malloc(tree_height * sizeof(int));

	if(p->level_sizes == NULL)
	{
		free(p);
		return NULL;
	}

	for(int i=0;i<tree_height;i++)
		p->level_sizes[i]=CALCULATE_TREE_SIZE(i+1);
#endif

	p->tree_height = tree_height;
	p->k_no_trials = k_no_trials;

	int allocated = preallocate_trees(p, NO_PREALLOCATED_TREES(tree_height));

	printf("Allocated %d / %d trees\n", allocated, NO_PREALLOCATED_TREES(tree_height));

	if(allocated < 1)
	{
		free_pool(p);
		return NULL;
	}

	atomic_init(&p->producer_tree, p->head);
	concurrent_pool_node_ptr_pair cts = { .prev = NULL, .crt = p->head };
	atomic_init(&p->consumer_trees, cts); // Set consumer pointer pair to (prev=NULL, current=producer=head)

	return p;
}

concurrent_pool * allocate_pool_with_tree_height(int tree_height)
{
	return _allocate_pool(tree_height, DEFAULT_K_NO_TRIALS);
}

concurrent_pool * allocate_pool()
{
	return _allocate_pool(DEFAULT_TREE_HEIGHT, DEFAULT_K_NO_TRIALS);
}

void set_tree_height(concurrent_pool * pool, int tree_height)
{
	pool->tree_height = tree_height;
}

void set_no_trials(concurrent_pool * pool, int no_trials)
{
	pool->k_no_trials = no_trials;
}

void free_pool(concurrent_pool * p)
{
	concurrent_pool_node_ptr pn = p->head, next_pn = NULL;

	while(pn != NULL)
	{
		next_pn = pn->next;
		free_pool_node(pn);
		pn = next_pn;
	}

#ifdef PRECALCULATE_TREE_LEVEL_SIZES
	free(p->level_sizes);
#endif
	free(p);
}

int move_consumer_ptr_back(concurrent_pool* pool, concurrent_pool_node_ptr producer_tree, concurrent_pool_node_ptr_pair c_ptrs_in)
{
	atomic_fetch_add(&(pool->old_producers), 1);

	concurrent_pool_node_ptr_pair c_ptrs = c_ptrs_in;

	while(1)
	{
		concurrent_pool_node_ptr_pair new_cts = { .prev = NULL, .crt = producer_tree };

		if(atomic_compare_exchange_strong(&(pool->consumer_trees), &c_ptrs, new_cts))
			break;

		if(c_ptrs.crt->node_id <= producer_tree->node_id)
			break;
	}

	atomic_fetch_add(&(pool->old_producers), -1);

	return 0;
}

// Note: This function is NOT supposed to be thread safe. Only call in pool constructor.
// Returns the number of successfully pre-allocated tree pools.

int preallocate_trees(concurrent_pool* pool, int no_trees)
{
	concurrent_pool_node_ptr crt_tree = NULL;

	// Find end of tree list:

	if(pool->producer_tree != NULL)
		for(crt_tree = pool->producer_tree; crt_tree->next != NULL; crt_tree = crt_tree->next);

	for(int i=0;i<no_trees;i++)
	{
#ifdef PRECALCULATE_TREE_LEVEL_SIZES
		concurrent_pool_node_ptr pool_node = allocate_pool_node(0, pool->tree_height, pool->level_sizes);
#else
		concurrent_pool_node_ptr pool_node = allocate_pool_node(0, pool->tree_height, NULL);
#endif

		if(pool_node == NULL)
			return i;

		if(crt_tree != NULL)
		{
			pool_node->node_id = crt_tree->node_id + 1;
			atomic_init(&crt_tree->next, pool_node);
		}
		else
		{
			pool->head = pool_node;
		}

		crt_tree = pool_node;
	}

	return no_trees;
}


int insert_new_tree(concurrent_pool* pool, concurrent_pool_node_ptr producer_tree_in)
{
	concurrent_pool_node_ptr producer_tree = producer_tree_in, next_ptr = atomic_load_explicit(&producer_tree_in->next, memory_order_relaxed);
#ifdef PRECALCULATE_TREE_LEVEL_SIZES
	concurrent_pool_node_ptr pool_node = allocate_pool_node(0, pool->tree_height, pool->level_sizes);
#else
	concurrent_pool_node_ptr pool_node = allocate_pool_node(0, pool->tree_height, NULL);
#endif

	if(pool_node == NULL)
		return -1;

	// Find end of tree list:

	while(next_ptr != NULL)
	{
		producer_tree = next_ptr;
		next_ptr = atomic_load_explicit(&producer_tree->next, memory_order_relaxed);
	}

	pool_node->node_id = producer_tree->node_id + 1;

	concurrent_pool_node_ptr old = NULL;

	// Attempt to chain our newly allocated tree pool to the end of the list.
	// If the CAS fails, it means a concurrent producer managed to extend the list before us,
	// in which case we free our newly allocated pool and return.

	if(!atomic_compare_exchange_strong(&(producer_tree->next), &old, pool_node))
		free_pool_node(pool_node);

	return 0;
}

int put(WORD task, concurrent_pool* pool)
{
	concurrent_pool_node_ptr producer_tree = NULL;
	int status = 0;
#ifdef PRECALCULATE_TREE_LEVEL_SIZES
	int * precalculated_level_sizes = pool->level_sizes;
#else
	int * precalculated_level_sizes = NULL;
#endif

	producer_tree = atomic_load_explicit(&pool->producer_tree, memory_order_relaxed);

	while(1)
	{
		int put_index = put_in_tree(task, producer_tree->tree, pool->tree_height, pool->k_no_trials, precalculated_level_sizes);

		if(put_index >= 0)
		{
#ifdef TASKPOOL_DEBUG
			printf("Successfully put task %ld in tree %d at index %d\n", (long) task, producer_tree->node_id, put_index);
#endif
			// Put succeeded in current tree, but we may need to move back consumer pointer if it overshot us:

			concurrent_pool_node_ptr_pair c_ptrs = atomic_load_explicit(&pool->consumer_trees, memory_order_relaxed);

			if(c_ptrs.crt->node_id > producer_tree->node_id)
			{
				move_consumer_ptr_back(pool, producer_tree, c_ptrs);
			}

			return 0;
		}
		else // current producer tree is "full"
		{
#ifdef TASKPOOL_DEBUG
			printf("put_in_tree() returned status %d when attempting to put task %ld in full tree %d. Next pointer is: %d\n", status, (long) task, producer_tree->node_id, (producer_tree->next != NULL)?(producer_tree->next->node_id):(-1));
#endif

			// It might be that another producer already inserted a new tree, so first check for that:

			atomic_concurrent_pool_node_ptr producer_tree_next = atomic_load_explicit(&producer_tree->next, memory_order_relaxed);

			if(producer_tree_next == NULL)
			{
				status = insert_new_tree(pool, producer_tree);

#ifdef TASKPOOL_DEBUG
				printf("insert_new_tree() returned status %d when attempting to put task %ld in full tree %d. Next pointer is: %d\n", status, (long) task, producer_tree->node_id, producer_tree->next->node_id);
#endif

				// Note the only failure condition is failure to allocate memory, otherwise inserts s'd always succeed:

				if(status != 0)
					return status;
			}

			// At this point a new tree was successfully linked into the list (either by us or by a concurrent producer).
			// We next attempt to progress the producer pointer of the pool. If that CAS fails, it just means that
			// some other producer managed to progress it before us, which is OK: we just continue and attempt
			// to put our task in the current producer tree of the pool:

			status = atomic_compare_exchange_strong(&(pool->producer_tree), &producer_tree, atomic_load_explicit(&producer_tree->next, memory_order_relaxed));

#ifdef TASKPOOL_DEBUG
			if(status != 1)
				printf("CAS returned status %d when attempting to progress producer pointer from %d to %d (after put failed in full tree %d).\n", status, old->node_id, producer_tree->next->node_id, old->node_id);
#endif
		}
	}
}

int get(WORD* task, concurrent_pool* pool)
{
	concurrent_pool_node_ptr producer_tree = NULL;
	concurrent_pool_node_ptr_pair consumer_ptrs = atomic_load_explicit(&pool->consumer_trees, memory_order_relaxed);

	while(1)
	{
		// First try the previous and current consumer pointers:

		if(consumer_ptrs.prev != NULL)
		{
#ifdef TASKPOOL_DEBUG
			printf("get() attempting to find a task in prev tree %d\n", consumer_ptrs.prev->node_id);
#endif

			if(get_from_tree(task, consumer_ptrs.prev->tree)==0)
			{
#ifdef TASKPOOL_DEBUG
			printf("get() found task %ld in prev tree %d\n", (long) *task, consumer_ptrs.prev->node_id);
#endif
				return 0;
			}

		}

		if(consumer_ptrs.crt != NULL)
		{
#ifdef TASKPOOL_DEBUG
			printf("get() attempting to find a task in crt tree %d\n", consumer_ptrs.crt->node_id);
#endif

			if(get_from_tree(task, consumer_ptrs.crt->tree)==0)
			{
#ifdef TASKPOOL_DEBUG
				printf("get() found task %ld in crt tree %d\n", (long) *task, consumer_ptrs.crt->node_id);
#endif
				return 0;
			}
		}

		producer_tree = atomic_load_explicit(&pool->producer_tree, memory_order_relaxed);

		if(producer_tree->node_id <= consumer_ptrs.crt->node_id)
		{
#ifdef TASKPOOL_DEBUG
			printf("get(): No new tasks exists (producer tree %d < consumer tree %d)\n", producer_tree->node_id, consumer_ptrs.crt->node_id);
#endif
			*task = NULL; // No new tasks exist
			return 1;
		}

		concurrent_pool_node_ptr_pair new_cts = { .prev = consumer_ptrs.crt, .crt = consumer_ptrs.crt->next };

		if(atomic_load_explicit(&pool->old_producers, memory_order_relaxed) == 0)
		{
			// Whether my CAS to update consumer pointers succeeds or not, use the most recent value
			// of the (prev, crt) pointer pair to retry grabbing tasks from the new tree pointers:

			atomic_compare_exchange_strong(&(pool->consumer_trees), &consumer_ptrs, new_cts);
		}
		else
		// If there are currently some producers attempting to move consumer pointer back, retry to read from
		// the (updated) consumer pointer again, but *do not* attempt to progress consumer pointer after that,
		// to avoid race condition:
		{
			consumer_ptrs = new_cts;
		}
	}
}


