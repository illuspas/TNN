// Tencent is pleased to support the open source community by making TNN available.
//
// Copyright (C) 2020 THL A29 Limited, a Tencent company. All rights reserved.
//
// Licensed under the BSD 3-Clause License (the "License"); you may not use this file except
// in compliance with the License. You may obtain a copy of the License at
//
// https://opensource.org/licenses/BSD-3-Clause
//
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

#include <metal_stdlib>
#include "tnn/device/metal/acc/metal_common.metal"

using namespace metal;

// x: [seq, batch, input]
// w: [dir, output, input, 4]
// gates: [dir, seq, batch, output, 4(IOFC)]
kernel void lstm_gates(const device ftype *x                    [[buffer(0)]],
                       const device ftype4 *w                   [[buffer(1)]],
                       device ftype4 *gates                     [[buffer(2)]],
                       constant MetalRecurrentParams& params     [[buffer(3)]],
                       uint3 gid  [[thread_position_in_grid]]) {
    if (any(gid >= uint3(params.hidden_size, params.batch, params.seq_len*params.direction))) return;
    
    short d = gid.z / params.seq_len;
    short t = gid.z % params.seq_len;
    short n = gid.y;
    short o = gid.x;
    
    auto weight = w + (d * params.hidden_size + o) * params.input_width;
    auto input  = x + (t * params.batch + n ) * params.input_width;
    auto output = gates + ((d * params.seq_len + t) * params.batch + n) * params.hidden_size + o;
    
    ftype4 result = 0;
    for(short i = 0; i<params.input_width; ++i) {
        result += weight[i] * input[i];
    }
    *output = result;
}

// gates: [dir, seq, batch, output, 4(IOFC)]
// cell:  [dir, batch, output]
// hidden:[dir, batch, output]
// bias:  [dir, output, 8]
// w:     [dir, output_out, output_in, 4]
// y:     [seq, batch, dir, output]
kernel void lstm_forward(const device ftype4 *gates      [[buffer(0)]],
                         const device ftype *c_0        [[buffer(1)]],
                         const device ftype *h_0        [[buffer(2)]],
                         threadgroup  ftype *h_local    [[threadgroup(0)]],
                         const device ftype4 *w         [[buffer(3)]],
                         const device ftype4 *b         [[buffer(4)]],
                         device ftype *c                [[buffer(5)]],
                         device ftype *h                [[buffer(6)]],
                         device ftype *y                [[buffer(7)]],
                         constant MetalRecurrentParams& params  [[buffer(8)]],
                         uint3 gid                            [[thread_position_in_grid]]) {
    
    if (any(gid >= uint3(params.hidden_size, params.batch, params.direction))) return;
    
    short d = gid.z;
    short n = gid.y;
    short o = gid.x;
    
    //threadgroup ftype h_local[256];
    
    auto cell   = params.has_init_c? c_0[(d* params.batch + n) * params.hidden_size + o] : 0;
    auto wh     = w + (d * params.hidden_size + o) * params.hidden_size;
    gates       = gates + (d * params.seq_len * params.batch + n) * params.hidden_size + o;
    ftype4 bias  = b[(d * params.hidden_size + o) * 2] + b[(d * params.hidden_size + o) * 2 + 1];
    
    // load initial cell and hidden state to local memory
    h_local[o] = params.has_init_h? h_0[(d* params.batch + n) * params.hidden_size + o] : 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    auto output = y + (n * params.direction + d) * params.hidden_size + o;
    bool forward = (params.direction == 1 && !params.reverse) || (params.direction == 2 && d == 0);
    
    for(short s=0; s<params.seq_len; ++s) {
        short t = forward? s : params.seq_len-1-s;
        ftype4 IOFC = gates[t * params.hidden_size * params.batch] + bias;
        for(short i=0; i<params.hidden_size; ++i) {
            IOFC += wh[i] * h_local[i];
        }
        
        ftype4 IOFF = IOFC.xyzz;
        ftype4 CCCC = IOFC.wwww;
        IOFF = 1.f / (1.f + exp(-IOFF));
        CCCC = tanh(CCCC);

        cell = IOFF.z * cell + IOFF.x * CCCC.x;
        ftype H = IOFF.y * tanh(cell);
        h_local[o] = H;
        output[t * params.hidden_size * params.direction * params.batch] = H;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    // write final hidden and cell to output
    c[(d* params.batch + n) * params.hidden_size + o] = cell;
    h[(d* params.batch + n) * params.hidden_size + o] = h_local[o];
}
