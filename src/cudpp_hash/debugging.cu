#include "debugging.cuh"

#include "hash_table.h"

#include <algorithm>
#include "cuda_util.h"

namespace CudaHT {
namespace CuckooHashing {

//! Debugging function: Takes statistics on the hash functions' distribution.
/*! Determines:
 *    - How many unique slots each key has.
 *    - How many keys hash into each slot.
 *    - Whether any keys failed to get a full set of slots.
 */
static __global__
void take_hash_function_statistics(const unsigned  *keys,
                                   const unsigned   n_entries,
                                   const unsigned   table_size,
                                   const uint2     *constants,
                                   const unsigned   num_functions,
                                         unsigned  *num_slots_available,
                                         unsigned  *num_hashing_in,
                                         unsigned  *failed) {
  unsigned thread_index = threadIdx.x +
                          blockIdx.x * blockDim.x +
                          blockIdx.y * blockDim.x * gridDim.x;

  if (thread_index >= n_entries)
    return;
  unsigned key = keys[thread_index];

  // Determine all of the locations the key hashes into.
  // Also count how many keys hash into each location.
  unsigned locations[kMaxHashFunctions];
  for (unsigned i = 0; i < num_functions; ++i) {
    locations[i] = hash_function_inner(constants[i], key) % table_size;

    if (num_hashing_in != NULL) {
      atomicAdd(num_hashing_in + locations[i], 1);
    }
  }

  // Determine whether all of the locations were different.
  unsigned num_slots = 1;
  for (unsigned i = 1; i < num_functions; ++i) {
    bool matched = false;
    for (unsigned j = 0; j < i; ++j) {
      if (locations[i] == locations[j]) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      num_slots++;
    }
  }

  if (num_slots_available != NULL) {
    num_slots_available[thread_index] = num_slots;
  }

  if (failed != NULL && num_slots != num_functions) {
    *failed = 1;
  }
}


void TakeHashFunctionStatistics(const unsigned   num_keys,
                                const unsigned  *d_keys,
                                const unsigned   table_size,
                                const uint2     *constants,
                                const unsigned   kNumHashFunctions) {
  char buffer[16000];
  PrintMessage("Hash function constants: ");

  for (unsigned i = 0; i < kNumHashFunctions; ++i) {
    sprintf(buffer, "\t%10u, %10u", constants[i].x, constants[i].y);
    PrintMessage(buffer);
  }

  unsigned *d_num_hashing_in = NULL;
 #ifdef COUNT_HOW_MANY_HASH_INTO_EACH_SLOT
  CUDA_SAFE_CALL(cudaMalloc((void**)&d_num_hashing_in,
                             sizeof(unsigned) * table_size));
  CUDA_SAFE_CALL(cudaMemset(d_num_hashing_in, 0, sizeof(unsigned) * table_size));
 #endif

  unsigned *d_num_slots_available = NULL;
 #ifdef COUNT_HOW_MANY_HAVE_CYCLES
  CUDA_SAFE_CALL(cudaMalloc((void**)&d_num_slots_available,
                            sizeof(unsigned) * num_keys));
 #endif
  uint2 *d_constants = NULL;
  CUDA_SAFE_CALL(cudaMalloc((void**)&d_constants, sizeof(uint2) * kNumHashFunctions));
  CUDA_SAFE_CALL(cudaMemcpy(d_constants, constants, sizeof(uint2) * kNumHashFunctions, cudaMemcpyHostToDevice));

  take_hash_function_statistics<<<ComputeGridDim(num_keys), kBlockSize>>>
                               (d_keys, num_keys,
                                table_size,
                                d_constants,
                                kNumHashFunctions,
                                d_num_slots_available,
                                d_num_hashing_in,
                                NULL);
  CUDA_SAFE_CALL(cudaFree(d_constants));

 #ifdef COUNT_HOW_MANY_HASH_INTO_EACH_SLOT
  unsigned *num_hashing_in = new unsigned[table_size];
  CUDA_SAFE_CALL(cudaMemcpy(num_hashing_in,
                            d_num_hashing_in,
                            sizeof(unsigned) * table_size,
                            cudaMemcpyDeviceToHost));

  /*
  // Print how many items hash into each slot.
  // Used to make sure items are spread evenly throughout the table.
  buffer[0] = '\0';
  PrintMessage("Num hashing into each: ", true);
  for (unsigned i = 0; i < table_size; ++i) {
    sprintf(buffer, "%s\t%2u", buffer, num_hashing_in[i]);
    if (i % 25 == 24) {
      PrintMessage(buffer, true);
      buffer[0] = '\0';
    }
  }
  PrintMessage(buffer,true);
  */

  // Print a histogram of how many items are hashed into each slot.  Shows
  // if average number of items hashing into each slot is low.
  std::sort(num_hashing_in, num_hashing_in + table_size);
  int count = 1;
  unsigned previous = num_hashing_in[0];
  sprintf(buffer, "Num items hashing into a slot:\t");
  PrintMessage(buffer);
  for (unsigned i = 1; i < table_size; ++i) {
    if (num_hashing_in[i] != previous) {
      sprintf(buffer, "\t(%u, %u)", previous, count);
      PrintMessage(buffer);
      previous = num_hashing_in[i];
      count = 1;
    } else {
      count++;
    }
  }
  sprintf(buffer, "\t(%u, %u)", previous, count);
  PrintMessage(buffer);

  delete [] num_hashing_in;
  CUDA_SAFE_CALL(cudaFree(d_num_hashing_in));
 #endif

 #ifdef COUNT_HOW_MANY_HAVE_CYCLES
  unsigned *num_slots_available = new unsigned[num_keys];
  CUDA_SAFE_CALL(cudaMemcpy(num_slots_available,
                            d_num_slots_available,
                            sizeof(unsigned) * num_keys,
                            cudaMemcpyDeviceToHost));

  static const unsigned kHistogramSize = kNumHashFunctions + 1;
  unsigned *histogram = new unsigned[kHistogramSize];
  memset(histogram, 0, sizeof(unsigned) * kHistogramSize);
  for (unsigned i = 0; i < num_keys; ++i) {
    histogram[num_slots_available[i]]++;
  }

  sprintf(buffer, "Slots assigned to each key: ");
  for (unsigned i = 1; i < kHistogramSize; ++i) {
    sprintf(buffer, "%s(%u, %u) ", buffer, i, histogram[i]);
  }
  PrintMessage(buffer);

  delete [] histogram;
  delete [] num_slots_available;
  CUDA_SAFE_CALL(cudaFree(d_num_slots_available));
 #endif
}


void OutputRetrievalStatistics(const unsigned  n_queries,
                               const unsigned *d_retrieval_probes,
                               const unsigned  n_functions)
{
  unsigned *retrieval_probes = new unsigned[n_queries];
  CUDA_SAFE_CALL(cudaMemcpy(retrieval_probes,
                            d_retrieval_probes,
                            sizeof(unsigned) * n_queries,
                            cudaMemcpyDeviceToHost));

  // Create a histogram showing how many items needed how many probes to be found.
  unsigned possible_probes = n_functions + 2;
  unsigned *histogram = new unsigned[possible_probes];
  memset(histogram, 0, sizeof(unsigned) * (possible_probes));
  for (unsigned i = 0; i < n_queries; ++i) {
    histogram[retrieval_probes[i]]++;
  }

  // Dump it.
  char buffer[10000];
  sprintf(buffer, "Probes for retrieval: ");
  PrintMessage(buffer);
  for (unsigned i = 0; i < possible_probes; ++i) {
    sprintf(buffer, "\t(%u, %u)", i, histogram[i]);
    PrintMessage(buffer);
  }
  delete [] retrieval_probes;
  delete [] histogram;
}

void OutputBuildStatistics(const unsigned  n,
                           const unsigned *d_iterations_taken) {
  // Output how many iterations each thread took until it found an empty slot.
  unsigned *iterations_taken = new unsigned[n];
  CUDA_SAFE_CALL(cudaMemcpy(iterations_taken, d_iterations_taken, sizeof(unsigned) * n, cudaMemcpyDeviceToHost));
  std::sort(iterations_taken, iterations_taken + n);
  unsigned total_iterations = 0;
  unsigned max_iterations_taken = 0;
  for (unsigned i = 0; i < n; ++i) {
    total_iterations += iterations_taken[i];
    max_iterations_taken = std::max(max_iterations_taken, iterations_taken[i]);
  }

  unsigned current_value = iterations_taken[0];
  unsigned count = 1;
  char buffer[10000];
  sprintf(buffer, "Iterations taken:\n");
  for (unsigned i = 1; i < n; ++i) {
    if (iterations_taken[i] != current_value) {
      sprintf(buffer, "%s\t(%u, %u)\n", buffer, current_value, count);
      current_value = iterations_taken[i];
      count = 1;
    } else {
      count++;
    }
  }
  sprintf(buffer, "%s\t(%u, %u)", buffer, current_value, count);
  PrintMessage(buffer);
  sprintf(buffer, "Total iterations: %u", total_iterations);
  PrintMessage(buffer);
  sprintf(buffer, "Avg/Med/Max iterations: (%f %u %u)", (float)total_iterations / n, iterations_taken[n/2], iterations_taken[n-1]);
  PrintMessage(buffer);
  delete [] iterations_taken;

  // Print the length of the longest eviction chain.
  sprintf(buffer, "Max iterations: %u", max_iterations_taken);
  PrintMessage(buffer);
}


void PrintStashContents(const Entry *d_stash) {
  Entry *stash = new Entry[CudaHT::CuckooHashing::kStashSize];
  CUDA_SAFE_CALL(cudaMemcpy(stash, d_stash, sizeof(Entry) * CudaHT::CuckooHashing::kStashSize, cudaMemcpyDeviceToHost));
  for (unsigned i = 0; i < CudaHT::CuckooHashing::kStashSize; ++i) {
    if (get_key(stash[i]) != kKeyEmpty) {
      char buffer[256];
      sprintf(buffer, "Stash[%u]: %u = %u", i, get_key(stash[i]), get_value(stash[i]));
      PrintMessage(buffer, true);
    }
  }
  delete [] stash;
}


}; // namespace CuckooHashing
}; // namespace CudaHT

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: