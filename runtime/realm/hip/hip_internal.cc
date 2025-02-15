/* Copyright 2021 Stanford University, NVIDIA Corporation
 *                Los Alamos National Laboratory
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "realm/hip/hip_internal.h"
#include "realm/hip/hip_module.h"

namespace Realm {
  
  extern Logger log_xd;

  namespace Hip {
    
    extern Logger log_stream;
    extern Logger log_gpudma;


    ////////////////////////////////////////////////////////////////////////
    //
    // class GPUXferDes

    GPUXferDes::GPUXferDes(uintptr_t _dma_op, Channel *_channel,
                           NodeID _launch_node, XferDesID _guid,
                           const std::vector<XferDesPortInfo>& inputs_info,
                           const std::vector<XferDesPortInfo>& outputs_info,
                           int _priority)
      : XferDes(_dma_op, _channel, _launch_node, _guid,
                inputs_info, outputs_info,
                _priority, 0, 0)
    {
      kind = XFER_GPU_IN_FB; // TODO: is this needed at all?

      src_gpus.resize(inputs_info.size(), 0);
      for(size_t i = 0; i < input_ports.size(); i++)
	      if(input_ports[i].mem->kind == MemoryImpl::MKIND_GPUFB)
          src_gpus[i] = (ID(input_ports[i].mem->me).is_memory() ?
                           (checked_cast<GPUFBMemory *>(input_ports[i].mem))->gpu :
                           (checked_cast<GPUFBIBMemory *>(input_ports[i].mem))->gpu);

      dst_gpus.resize(outputs_info.size(), 0);
      for(size_t i = 0; i < output_ports.size(); i++)
        if(output_ports[i].mem->kind == MemoryImpl::MKIND_GPUFB)
          dst_gpus[i] = (ID(output_ports[i].mem->me).is_memory() ?
                           (checked_cast<GPUFBMemory *>(output_ports[i].mem))->gpu :
                           (checked_cast<GPUFBIBMemory *>(output_ports[i].mem))->gpu);
    }
	
    long GPUXferDes::get_requests(Request** requests, long nr)
    {
      // unused
      assert(0);
      return 0;
    }

        bool GPUXferDes::progress_xd(GPUChannel *channel,
                                 TimeLimit work_until)
    {
      bool did_work = false;

      ReadSequenceCache rseqcache(this, 2 << 20);
      WriteSequenceCache wseqcache(this, 2 << 20);

      while(true) {
        size_t min_xfer_size = 4 << 20;  // TODO: make controllable
        size_t max_bytes = get_addresses(min_xfer_size, &rseqcache);
        if(max_bytes == 0)
          break;

        XferPort *in_port = 0, *out_port = 0;
        size_t in_span_start = 0, out_span_start = 0;
        GPU *in_gpu = 0, *out_gpu = 0;
        if(input_control.current_io_port >= 0) {
          in_port = &input_ports[input_control.current_io_port];
          in_span_start = in_port->local_bytes_total;
          in_gpu = src_gpus[input_control.current_io_port];
        }
        if(output_control.current_io_port >= 0) {
          out_port = &output_ports[output_control.current_io_port];
          out_span_start = out_port->local_bytes_total;
          out_gpu = dst_gpus[output_control.current_io_port];
        }

        size_t total_bytes = 0;
        if(in_port != 0) {
          if(out_port != 0) {
            // input and output both exist - transfer what we can
            log_xd.info() << "hip memcpy chunk: min=" << min_xfer_size
                          << " max=" << max_bytes;

            uintptr_t in_base = reinterpret_cast<uintptr_t>(in_port->mem->get_direct_ptr(0, 0));
            uintptr_t out_base = reinterpret_cast<uintptr_t>(out_port->mem->get_direct_ptr(0, 0));

            // pick the correct stream for any memcpy's we generate
            GPUStream *stream;
            if(in_gpu) {
              if(out_gpu == in_gpu)
                stream = in_gpu->get_next_d2d_stream();
              else if(!out_gpu)
                stream = in_gpu->device_to_host_stream;
              else {
                stream = in_gpu->peer_to_peer_streams[out_gpu->info->index];
                assert(stream);
              }
            } else {
              assert(out_gpu);
              stream = out_gpu->host_to_device_stream;
            }

            AutoGPUContext agc(stream->get_gpu());

            size_t bytes_to_fence = 0;

            while(total_bytes < max_bytes) {
              AddressListCursor& in_alc = in_port->addrcursor;
              AddressListCursor& out_alc = out_port->addrcursor;

              uintptr_t in_offset = in_alc.get_offset();
              uintptr_t out_offset = out_alc.get_offset();

              // the reported dim is reduced for partially consumed address
              //  ranges - whatever we get can be assumed to be regular
              int in_dim = in_alc.get_dim();
              int out_dim = out_alc.get_dim();

              size_t bytes = 0;
              size_t bytes_left = max_bytes - total_bytes;

              // limit transfer size for host<->device copies
              if((bytes_left > (4 << 20)) && (!in_gpu || !out_gpu))
                bytes_left = 4 << 20;

              assert(in_dim > 0);
              assert(out_dim > 0);

              size_t icount = in_alc.remaining(0);
              size_t ocount = out_alc.remaining(0);

              // contig bytes is always the min of the first dimensions
              size_t contig_bytes = std::min(std::min(icount, ocount),
                                             bytes_left);

              // catch simple 1D case first
              if((contig_bytes == bytes_left) ||
                 ((contig_bytes == icount) && (in_dim == 1)) ||
                 ((contig_bytes == ocount) && (out_dim == 1))) {
                bytes = contig_bytes;

                // check rate limit on stream
                if(!stream->ok_to_submit_copy(bytes, this))
                  break;

                // grr...  prototypes of these differ slightly...
                hipMemcpyKind copy_type;
                if(in_gpu) {
                  if(out_gpu == in_gpu)
                    copy_type = hipMemcpyDeviceToDevice;
                  else if(!out_gpu)
                    copy_type = hipMemcpyDeviceToHost;
                  else {
                    copy_type = hipMemcpyDefault;
                  }
                } else {
                  copy_type = hipMemcpyHostToDevice;
                }
                CHECK_CU( hipMemcpyAsync(reinterpret_cast<void *>(out_base + out_offset),
                                         reinterpret_cast<const void *>(in_base + in_offset),
                                         bytes, copy_type,
                                         stream->get_stream()) );
                log_gpudma.info() << "gpu memcpy: dst="
                                  << std::hex << (out_base + out_offset)
                                  << " src=" << (in_base + in_offset) << std::dec
                                  << " bytes=" << bytes << " stream=" << stream;

                in_alc.advance(0, bytes);
                out_alc.advance(0, bytes);

                bytes_to_fence += bytes;
                // TODO: fence on a threshold
              } else {
                // grow to a 2D copy
                int id;
                int iscale;
                uintptr_t in_lstride;
                if(contig_bytes < icount) {
                  // second input dim comes from splitting first
                  id = 0;
                  in_lstride = contig_bytes;
                  size_t ilines = icount / contig_bytes;
                  if((ilines * contig_bytes) != icount)
                    in_dim = 1;  // leftover means we can't go beyond this
                  icount = ilines;
                  iscale = contig_bytes;
                } else {
                  assert(in_dim > 1);
                  id = 1;
                  icount = in_alc.remaining(id);
                  in_lstride = in_alc.get_stride(id);
                  iscale = 1;
                }

                int od;
                int oscale;
                uintptr_t out_lstride;
                if(contig_bytes < ocount) {
                  // second output dim comes from splitting first
                  od = 0;
                  out_lstride = contig_bytes;
                  size_t olines = ocount / contig_bytes;
                  if((olines * contig_bytes) != ocount)
                    out_dim = 1;  // leftover means we can't go beyond this
                  ocount = olines;
                  oscale = contig_bytes;
                } else {
                  assert(out_dim > 1);
                  od = 1;
                  ocount = out_alc.remaining(od);
                  out_lstride = out_alc.get_stride(od);
                  oscale = 1;
                }

                size_t lines = std::min(std::min(icount, ocount),
                                        bytes_left / contig_bytes);

                // see if we need to stop at 2D
                if(((contig_bytes * lines) == bytes_left) ||
                   ((lines == icount) && (id == (in_dim - 1))) ||
                   ((lines == ocount) && (od == (out_dim - 1)))) {
                  bytes = contig_bytes * lines;

                  // check rate limit on stream
                  if(!stream->ok_to_submit_copy(bytes, this))
                    break;
                  
                  hipMemcpyKind copy_type;
                  if(in_gpu) {
                    if(out_gpu == in_gpu)
                      copy_type = hipMemcpyDeviceToDevice;
                    else if(!out_gpu)
                      copy_type = hipMemcpyDeviceToHost;
                    else {
                      copy_type = hipMemcpyDefault;
                    }
                  } else {
                    copy_type = hipMemcpyHostToDevice;
                  }

                  const void *src = reinterpret_cast<const void *>(in_base + in_offset);
                  void *dst = reinterpret_cast<void *>(out_base + out_offset);

                  CHECK_CU( hipMemcpy2DAsync(dst, out_lstride, src, in_lstride, contig_bytes, lines, copy_type, stream->get_stream()) );

                  log_gpudma.info() << "gpu memcpy 2d: dst="
                                    << std::hex << (out_base + out_offset) << std::dec
                                    << "+" << out_lstride << " src="
                                    << std::hex << (in_base + in_offset) << std::dec
                                    << "+" << in_lstride
                                    << " bytes=" << bytes << " lines=" << lines
                                    << " stream=" << stream;

                  in_alc.advance(id, lines * iscale);
                  out_alc.advance(od, lines * oscale);

                  bytes_to_fence += bytes;
                  // TODO: fence on a threshold
                } else {
                  uintptr_t in_pstride;
                  if(lines < icount) {
                    // third input dim comes from splitting current
                    in_pstride = in_lstride * lines;
                    size_t iplanes = icount / lines;
                    // check for leftovers here if we go beyond 3D!
                    icount = iplanes;
                    iscale *= lines;
                  } else {
                    id++;
                    assert(in_dim > id);
                    icount = in_alc.remaining(id);
                    in_pstride = in_alc.get_stride(id);
                    iscale = 1;
                  }

                  uintptr_t out_pstride;
                  if(lines < ocount) {
                    // third output dim comes from splitting current
                    out_pstride = out_lstride * lines;
                    size_t oplanes = ocount / lines;
                    // check for leftovers here if we go beyond 3D!
                    ocount = oplanes;
                    oscale *= lines;
                  } else {
                    od++;
                    assert(out_dim > od);
                    ocount = out_alc.remaining(od);
                    out_pstride = out_alc.get_stride(od);
                    oscale = 1;
                  }

                  size_t planes = std::min(std::min(icount, ocount),
                                           (bytes_left /
                                            (contig_bytes * lines)));

                  // a cuMemcpy3DAsync appears to be unrolled on the host in the
                  //  driver, so we'll do the unrolling into 2D copies ourselves,
                  //  allowing us to stop early if we hit the rate limit or a
                  //  timeout
                  hipMemcpyKind copy_type;
                    if(in_gpu) {
                    if(out_gpu == in_gpu)
                      copy_type = hipMemcpyDeviceToDevice;
                    else if(!out_gpu)
                      copy_type = hipMemcpyDeviceToHost;
                    else {
                      copy_type = hipMemcpyDefault;
                    }
                  } else {
                    copy_type = hipMemcpyHostToDevice;
                  }

                  size_t act_planes = 0;
                  while(act_planes < planes) {
                    // check rate limit on stream
                    if(!stream->ok_to_submit_copy(contig_bytes * lines, this))
                      break;

                    const void *src = reinterpret_cast<const void *>(in_base + in_offset + (act_planes * in_pstride));
                    void *dst = reinterpret_cast<void *>(out_base + out_offset + (act_planes * out_pstride));

                    CHECK_CU( hipMemcpy2DAsync(dst, out_lstride, src, in_lstride, contig_bytes, lines, copy_type, stream->get_stream()) );
                    act_planes++;

                    if(work_until.is_expired())
                      break;
                  }

                  if(act_planes == 0)
                    break;

                  log_gpudma.info() << "gpu memcpy 3d: dst="
                                    << std::hex << (out_base + out_offset) << std::dec
                                    << "+" << out_lstride
                                    << "+" << out_pstride << " src="
                                    << std::hex << (in_base + in_offset) << std::dec
                                    << "+" << in_lstride
                                    << "+" << in_pstride 
                                    << " bytes=" << bytes << " lines=" << lines
                                    << " planes=" << act_planes
                                    << " stream=" << stream;

                  bytes = contig_bytes * lines * act_planes;
                  in_alc.advance(id, act_planes * iscale);
                  out_alc.advance(od, act_planes * oscale);

                  bytes_to_fence += bytes;
                  // TODO: fence on a threshold
                }
              }

#ifdef DEBUG_REALM
              assert(bytes <= bytes_left);
#endif
              total_bytes += bytes;

              // stop if it's been too long, but make sure we do at least the
              //  minimum number of bytes
              if((total_bytes >= min_xfer_size) && work_until.is_expired()) break;
            }

            if(bytes_to_fence > 0) {
              add_reference(); // released by transfer completion
              log_gpudma.info() << "gpu memcpy fence: stream=" << stream
                                << " xd=" << std::hex << guid << std::dec
                                << " bytes=" << total_bytes;

              stream->add_notification(new GPUTransferCompletion(this,
                                                                 input_control.current_io_port,
                                                                 in_span_start,
                                                                 total_bytes,
                                                                 output_control.current_io_port,
                                                                 out_span_start,
                                                                 total_bytes));
              in_span_start += total_bytes;
              out_span_start += total_bytes;
            }
          } else {
            // input but no output, so skip input bytes
            total_bytes = max_bytes;
            in_port->addrcursor.skip_bytes(total_bytes);

            rseqcache.add_span(input_control.current_io_port,
                               in_span_start, total_bytes);
            in_span_start += total_bytes;
          }
        } else {
          if(out_port != 0) {
            // output but no input, so skip output bytes
            total_bytes = max_bytes;
            out_port->addrcursor.skip_bytes(total_bytes);
          } else {
            // skipping both input and output is possible for simultaneous
            //  gather+scatter
            total_bytes = max_bytes;

            wseqcache.add_span(output_control.current_io_port,
                               out_span_start, total_bytes);
            out_span_start += total_bytes;

          }
        }

        if(total_bytes > 0) {
          did_work = true;

          bool done = record_address_consumption(total_bytes, total_bytes);

          if(done || work_until.is_expired())
            break;
        }
      }
          
      rseqcache.flush();
      wseqcache.flush();

      return did_work;
    }


    ////////////////////////////////////////////////////////////////////////
    //
    // class GPUChannel

    GPUChannel::GPUChannel(GPU* _src_gpu, XferDesKind _kind,
                           BackgroundWorkManager *bgwork)
      : SingleXDQChannel<GPUChannel,GPUXferDes>(bgwork,
                                                _kind,
                                                stringbuilder() << "hip channel (gpu=" << _src_gpu->info->index << " kind=" << (int)_kind << ")")
    {
      src_gpu = _src_gpu;
        
      // switch out of ordered mode if multi-threaded dma is requested
      if(_src_gpu->module->cfg_multithread_dma)
        xdq.ordered_mode = false;

      std::vector<Memory> local_gpu_mems;
      local_gpu_mems.push_back(src_gpu->fbmem->me);
      if(src_gpu->fb_ibmem)
        local_gpu_mems.push_back(src_gpu->fb_ibmem->me);

      std::vector<Memory> peer_gpu_mems;
      peer_gpu_mems.insert(peer_gpu_mems.end(),
                           src_gpu->peer_fbs.begin(),
                           src_gpu->peer_fbs.end());

      std::vector<Memory> mapped_cpu_mems;
      mapped_cpu_mems.insert(mapped_cpu_mems.end(),
                             src_gpu->pinned_sysmems.begin(),
                             src_gpu->pinned_sysmems.end());
      // TODO:managed memory
      // // treat managed memory as usually being on the host as well
      // mapped_cpu_mems.insert(mapped_cpu_mems.end(),
      //                        src_gpu->managed_mems.begin(),
      //                        src_gpu->managed_mems.end());

      switch(_kind) {
      case XFER_GPU_TO_FB:
        {
          unsigned bw = 10000;  // HACK - estimate at 10 GB/s
          unsigned latency = 1000;  // HACK - estimate at 1 us
          unsigned frag_overhead = 2000;  // HACK - estimate at 2 us
          
          add_path(mapped_cpu_mems,
                   local_gpu_mems,
                   bw, latency, frag_overhead, XFER_GPU_TO_FB)
            .set_max_dim(2); // D->H cudamemcpy3d is unrolled into 2d copies
          
          break;
        }

      case XFER_GPU_FROM_FB:
        {
          unsigned bw = 10000;  // HACK - estimate at 10 GB/s
          unsigned latency = 1000;  // HACK - estimate at 1 us
          unsigned frag_overhead = 2000;  // HACK - estimate at 2 us

          add_path(local_gpu_mems,
                   mapped_cpu_mems,
                   bw, latency, frag_overhead, XFER_GPU_FROM_FB)
            .set_max_dim(2); // H->D cudamemcpy3d is unrolled into 2d copies

          break;
        }

      case XFER_GPU_IN_FB:
        {
          // self-path
          unsigned bw = 200000;  // HACK - estimate at 200 GB/s
          unsigned latency = 250;  // HACK - estimate at 250 ns
          unsigned frag_overhead = 2000;  // HACK - estimate at 2 us

          add_path(local_gpu_mems,
                   local_gpu_mems,
                   bw, latency, frag_overhead, XFER_GPU_IN_FB)
            .set_max_dim(3);

          break;
        }

      case XFER_GPU_PEER_FB:
        {
          // just do paths to peers - they'll do the other side
          unsigned bw = 50000;  // HACK - estimate at 50 GB/s
          unsigned latency = 1000;  // HACK - estimate at 1 us
          unsigned frag_overhead = 2000;  // HACK - estimate at 2 us

          add_path(local_gpu_mems,
                   peer_gpu_mems,
                   bw, latency, frag_overhead, XFER_GPU_PEER_FB)
            .set_max_dim(3);    

          break;
        }

      default:
        assert(0);
      }
    }

    GPUChannel::~GPUChannel()
    {
    }

    XferDes *GPUChannel::create_xfer_des(uintptr_t dma_op,
                                         NodeID launch_node,
                                         XferDesID guid,
                                         const std::vector<XferDesPortInfo>& inputs_info,
                                         const std::vector<XferDesPortInfo>& outputs_info,
                                         int priority,
                                         XferDesRedopInfo redop_info,
                                         const void *fill_data, size_t fill_size)
    {
      assert(redop_info.id == 0);
      assert(fill_size == 0);
      return new GPUXferDes(dma_op, this, launch_node, guid,
                            inputs_info, outputs_info,
                            priority);
    }

    long GPUChannel::submit(Request** requests, long nr)
    {
      // unused
      assert(0);
      return 0;
    }


    ////////////////////////////////////////////////////////////////////////
    //
    // class GPUCompletionEvent

      void GPUCompletionEvent::request_completed(void)
      {
	req->xd->notify_request_read_done(req);
	req->xd->notify_request_write_done(req);
      }

    ////////////////////////////////////////////////////////////////////////
    //
    // class GPUTransfercompletion
      
    GPUTransferCompletion::GPUTransferCompletion(XferDes *_xd,
                                                     int _read_port_idx,
                                                     size_t _read_offset,
                                                     size_t _read_size,
                                                     int _write_port_idx,
                                                     size_t _write_offset,
                                                     size_t _write_size)
        : xd(_xd)
        , read_port_idx(_read_port_idx)
        , read_offset(_read_offset)
        , read_size(_read_size)
        , write_port_idx(_write_port_idx)
        , write_offset(_write_offset)
        , write_size(_write_size)
      {}

      void GPUTransferCompletion::request_completed(void)
      {
	log_gpudma.info() << "gpu memcpy complete: xd=" << std::hex << xd->guid << std::dec
                        << " read=" << read_port_idx << "/" << read_offset
                        << " write=" << write_port_idx << "/" << write_offset
                        << " bytes=" << write_size;
        if(read_port_idx >= 0)
          xd->update_bytes_read(read_port_idx, read_offset, read_size);
        if(write_port_idx >= 0)
          xd->update_bytes_write(write_port_idx, write_offset, write_size);
        xd->remove_reference();
        delete this;  // TODO: recycle these!
      }


      ////////////////////////////////////////////////////////////////////////
      //
      // class GPUfillXferDes

      GPUfillXferDes::GPUfillXferDes(uintptr_t _dma_op, Channel *_channel,
                                     NodeID _launch_node, XferDesID _guid,
                                     const std::vector<XferDesPortInfo>& inputs_info,
                                     const std::vector<XferDesPortInfo>& outputs_info,
                                     int _priority,
                                     const void *_fill_data, size_t _fill_size)
        : XferDes(_dma_op, _channel, _launch_node, _guid,
                  inputs_info, outputs_info,
                  _priority, _fill_data, _fill_size)
      {
        kind = XFER_GPU_IN_FB;

        // no direct input data for us
        assert(input_control.control_port_idx == -1);
        input_control.current_io_port = -1;

        // cuda memsets are ideally 8/16/32 bits, so try to _reduce_ the fill
        //  size if there's duplication
        if((fill_size > 1) && (memcmp(fill_data,
                                      static_cast<char *>(fill_data) + 1,
                                      fill_size - 1) == 0))
          reduced_fill_size = 1;  // can use memset8
        else if((fill_size > 2) && ((fill_size >> 1) == 0) &&
                (memcmp(fill_data,
                        static_cast<char *>(fill_data) + 2,
                        fill_size - 2) == 0))
          reduced_fill_size = 2;  // can use memset16
        else if((fill_size > 4) && ((fill_size >> 2) == 0) &&
                (memcmp(fill_data,
                        static_cast<char *>(fill_data) + 4,
                        fill_size - 4) == 0))
          reduced_fill_size = 4;  // can use memset32
        else
          reduced_fill_size = fill_size; // will have to do it in pieces
      }

      long GPUfillXferDes::get_requests(Request** requests, long nr)
      {
        // unused
        assert(0);
        return 0;
      }

      bool GPUfillXferDes::progress_xd(GPUfillChannel *channel,
                                       TimeLimit work_until)
      {
        bool did_work = false;
        ReadSequenceCache rseqcache(this, 2 << 20);
        WriteSequenceCache wseqcache(this, 2 << 20);

        while(true) {
          size_t min_xfer_size = 4096;  // TODO: make controllable
          size_t max_bytes = get_addresses(min_xfer_size, &rseqcache);
          if(max_bytes == 0)
            break;

          XferPort *out_port = 0;
          size_t out_span_start = 0;
          if(output_control.current_io_port >= 0) {
            out_port = &output_ports[output_control.current_io_port];
            out_span_start = out_port->local_bytes_total;
          }

          bool done = false;

          size_t total_bytes = 0;
          if(out_port != 0) {
            // input and output both exist - transfer what we can
            log_xd.info() << "gpufill chunk: min=" << min_xfer_size
                          << " max=" << max_bytes;

            uintptr_t out_base = reinterpret_cast<uintptr_t>(out_port->mem->get_direct_ptr(0, 0));

            AutoGPUContext agc(channel->gpu);
            GPUStream *stream = channel->gpu->get_next_d2d_stream();

            while(total_bytes < max_bytes) {
              AddressListCursor& out_alc = out_port->addrcursor;

              uintptr_t out_offset = out_alc.get_offset();

              // the reported dim is reduced for partially consumed address
              //  ranges - whatever we get can be assumed to be regular
              int out_dim = out_alc.get_dim();

              // fast paths for 8/16/32 bit memsets exist for 1-D and 2-D
              switch(reduced_fill_size) {
              case 1: {
                // memset8
                uint8_t fill_u8;
                memcpy(&fill_u8, fill_data, 1);
                if(out_dim == 1) {
                  size_t bytes = out_alc.remaining(0);
                  CHECK_CU( hipMemsetD8Async((hipDeviceptr_t)(out_base + out_offset),
                                            fill_u8,
                                            bytes,
                                            stream->get_stream()) );
                  out_alc.advance(0, bytes);
                  total_bytes += bytes;
                } else {
                  size_t bytes = out_alc.remaining(0);
                  size_t lines = out_alc.remaining(1);
                  CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset),
                                              out_alc.get_stride(1),
                                              *reinterpret_cast<const uint8_t *>(fill_data),
                                              bytes, lines,
                                              stream->get_stream()) );
                  out_alc.advance(1, lines);
                  total_bytes += bytes * lines;
                }
                break;
              }

              case 2: {
                // memset16
                uint16_t fill_u16;
                memcpy(&fill_u16, fill_data, 2);
                if(out_dim == 1) {
                  size_t bytes = out_alc.remaining(0);
  #ifdef DEBUG_REALM
                  assert((bytes & 1) == 0);
  #endif
                  CHECK_CU( hipMemsetD16Async((hipDeviceptr_t)(out_base + out_offset),
                                             fill_u16,
                                             bytes >> 1,
                                             stream->get_stream()) );
                  out_alc.advance(0, bytes);
                  total_bytes += bytes;
                } else {
                  size_t bytes = out_alc.remaining(0);
                  size_t lines = out_alc.remaining(1);
  #ifdef DEBUG_REALM
                  assert((bytes & 1) == 0);
                  assert((out_alc.get_stride(1) & 1) == 0);
  #endif
                  CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset),
                                               out_alc.get_stride(1),
                                               *reinterpret_cast<const uint8_t *>(fill_data),
                                               bytes, lines,
                                               stream->get_stream()) );
                  out_alc.advance(1, lines);
                  total_bytes += bytes * lines;
                }
                break;
              }

              case 4: {
                // memset32
                uint32_t fill_u32;
                memcpy(&fill_u32, fill_data, 4);
                if(out_dim == 1) {
                  size_t bytes = out_alc.remaining(0);
  #ifdef DEBUG_REALM
                  assert((bytes & 3) == 0);
  #endif
                  CHECK_CU( hipMemsetD32Async((hipDeviceptr_t)(out_base + out_offset),
                                             fill_u32,
                                             bytes >> 2,
                                             stream->get_stream()) );
                  out_alc.advance(0, bytes);
                  total_bytes += bytes;
                } else {
                  size_t bytes = out_alc.remaining(0);
                  size_t lines = out_alc.remaining(1);
  #ifdef DEBUG_REALM
                  assert((bytes & 3) == 0);
                  assert((out_alc.get_stride(1) & 3) == 0);
  #endif
                  CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset),
                                               out_alc.get_stride(1),
                                               *reinterpret_cast<const uint8_t *>(fill_data),
                                               bytes, lines,
                                               stream->get_stream()) );
                  out_alc.advance(1, lines);
                  total_bytes += bytes * lines;
                }
                break;
              }

              default: {
                // more general approach - use strided 2d copies to fill the first
                //  line, and then we can use logarithmic doublings to deal with
                //  multiple lines and/or planes
                size_t bytes = out_alc.remaining(0);
                size_t elems = bytes / reduced_fill_size;
  #ifdef DEBUG_REALM
                assert((bytes % reduced_fill_size) == 0);
  #endif
                size_t partial_bytes = 0;
                // if((reduced_fill_size & 3) == 0) {
                //   // 32-bit partial fills allowed
                //   while(partial_bytes <= (reduced_fill_size - 4)) {
                //     uint32_t fill_u32;
                //     memcpy(&fill_u32,
                //            reinterpret_cast<const uint8_t *>(fill_data) + partial_bytes,
                //            4);
                //     CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset + partial_bytes),
                //                                  reduced_fill_size,
                //                                  fill_u32,
                //                                  1 /*"width"*/, elems /*"height"*/,
                //                                  stream->get_stream()) );
                //     partial_bytes += 4;
                //   }
                // }
                // if((reduced_fill_size & 1) == 0) {
                //   // 16-bit partial fills allowed
                //   while(partial_bytes <= (reduced_fill_size - 2)) {
                //     uint16_t fill_u16;
                //     memcpy(&fill_u16,
                //            reinterpret_cast<const uint8_t *>(fill_data) + partial_bytes,
                //            2);                                              
                //     CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset + partial_bytes),
                //                                  reduced_fill_size,
                //                                  fill_u16,
                //                                  1 /*"width"*/, elems /*"height"*/,
                //                                  stream->get_stream()) );
                //     partial_bytes += 2;
                //   }
                // }
                // leftover or unaligned bytes are done 8 bits at a time
                while(partial_bytes < reduced_fill_size) {
                  uint8_t fill_u8;
                  memcpy(&fill_u8,
                         reinterpret_cast<const uint8_t *>(fill_data) + partial_bytes,
                         1);
                  CHECK_CU( hipMemset2DAsync((void*)(out_base + out_offset + partial_bytes),
                                             reduced_fill_size,
                                             fill_u8,
                                             1 /*"width"*/, elems /*"height"*/,
                                             stream->get_stream()) );
                  partial_bytes += 1;
                }

                if(out_dim == 1) {
                  // all done
                  out_alc.advance(0, bytes);
                  total_bytes += bytes;
                } else {
                  size_t lines = out_alc.remaining(1);
                  size_t lstride = out_alc.get_stride(1);
                  printf("memset memcpy2d\n");

                  void *srcDevice = (void*)(out_base + out_offset);

                  size_t lines_done = 1;  // first line already valid
                  while(lines_done < lines) {
                    size_t todo = std::min(lines_done, lines - lines_done);
                    void *dstDevice = (void*)(out_base + out_offset +
                                                   (lines_done * lstride));
                    CHECK_CU( hipMemcpy2DAsync(dstDevice, lstride, srcDevice, lstride, bytes, todo, hipMemcpyDeviceToDevice, stream->get_stream()) );
                    lines_done += todo;
                  }

                  if(out_dim == 2) {
                    out_alc.advance(1, lines);
                    total_bytes += bytes * lines;
                  } else {
                    size_t planes = out_alc.remaining(2);
                    size_t pstride = out_alc.get_stride(2);

                    // logarithmic version requires that pstride be a multiple of
                    //  lstride
                    if((pstride % lstride) == 0) {
                      printf("memset memcpy3d\n");
                      hipMemcpy3DParms copy3d = {0};
                      void *srcDevice = (void*)(out_base + out_offset);
                      copy3d.srcPtr = make_hipPitchedPtr((void*)srcDevice, lstride, bytes, pstride/lstride);
                      copy3d.srcPos = make_hipPos(0,0,0);
                      copy3d.dstPos = make_hipPos(0,0,0);
#ifdef __HIP_PLATFORM_NVCC__
                      copy3d.kind = cudaMemcpyDeviceToDevice;
#else
                      copy3d.kind = hipMemcpyDeviceToDevice;
#endif

                      size_t planes_done = 1;  // first plane already valid
                      while(planes_done < planes) {
                        size_t todo = std::min(planes_done, planes - planes_done);
                        void *dstDevice = (void*)(out_base + out_offset +
                                                  (planes_done * pstride));
                        copy3d.dstPtr = make_hipPitchedPtr(dstDevice, lstride, bytes, pstride/lstride);
                        copy3d.extent = make_hipExtent(bytes, lines, todo);
                        CHECK_CU( hipMemcpy3DAsync(&copy3d, stream->get_stream()) );
                        planes_done += todo;
                      }

                      out_alc.advance(2, planes);
                      total_bytes += bytes * lines * planes;
                    } else {
                      // plane-at-a-time fallback - can reuse most of copy2d
                      //  setup above

                      for(size_t p = 1; p < planes; p++) {
                        void *dstDevice = (void*)(out_base + out_offset +
                                                       (p * pstride));
                        CHECK_CU( hipMemcpy2DAsync(dstDevice, lstride, srcDevice, lstride, bytes, lines, hipMemcpyDeviceToDevice, stream->get_stream()) );
                      }
                    }
                  }
                }
                break;
              }
              }

              // stop if it's been too long, but make sure we do at least the
              //  minimum number of bytes
              if((total_bytes >= min_xfer_size) && work_until.is_expired()) break;
            }

            // however many fills/copies we submitted, put in a single fence that
            //  will tell us that they're all done
            add_reference(); // released by transfer completion
            stream->add_notification(new GPUTransferCompletion(this,
                                                               -1, 0, 0,
                                                               output_control.current_io_port,
                                                               out_span_start,
                                                               total_bytes));
  	  out_span_start += total_bytes;

  	  done = record_address_consumption(total_bytes, total_bytes);
          }

          did_work = true;

          output_control.remaining_count -= total_bytes;
          if(output_control.control_port_idx >= 0)
            done = ((output_control.remaining_count == 0) &&
                    output_control.eos_received);

          if(done)
            iteration_completed.store_release(true);

          if(done || work_until.is_expired())
            break;
        }

        rseqcache.flush();

        return did_work;
      }


      ////////////////////////////////////////////////////////////////////////
      //
      // class GPUfillChannel

      GPUfillChannel::GPUfillChannel(GPU *_gpu, BackgroundWorkManager *bgwork)
        : SingleXDQChannel<GPUfillChannel,GPUfillXferDes>(bgwork,
                                                          XFER_GPU_IN_FB,
                                                          stringbuilder() << "cuda fill channel (gpu=" << _gpu->info->index << ")")
        , gpu(_gpu)
      {
        Memory fbm = gpu->fbmem->me;

        unsigned bw = 300000;  // HACK - estimate at 300 GB/s
        unsigned latency = 250;  // HACK - estimate at 250 ns
        unsigned frag_overhead = 2000;  // HACK - estimate at 2 us

        add_path(Memory::NO_MEMORY, fbm, bw, latency, frag_overhead, XFER_GPU_IN_FB)
          .set_max_dim(2);

        xdq.add_to_manager(bgwork);
      }

      XferDes *GPUfillChannel::create_xfer_des(uintptr_t dma_op,
                                               NodeID launch_node,
                                               XferDesID guid,
                                               const std::vector<XferDesPortInfo>& inputs_info,
                                               const std::vector<XferDesPortInfo>& outputs_info,
                                               int priority,
                                               XferDesRedopInfo redop_info,
                                               const void *fill_data, size_t fill_size)
      {
        assert(redop_info.id == 0);
        return new GPUfillXferDes(dma_op, this, launch_node, guid,
                                  inputs_info, outputs_info,
                                  priority,
                                  fill_data, fill_size);
      }

      long GPUfillChannel::submit(Request** requests, long nr)
      {
        // unused
        assert(0);
        return 0;
      }


  }; // namespace Hip

}; // namespace Realm
