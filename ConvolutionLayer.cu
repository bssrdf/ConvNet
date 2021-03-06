/*
 * ConvolutionLayer.cpp
 *
 *  Created on: May 6, 2016
 *      Author: jamiecho
 */

#include "ConvolutionLayer.h"


__device__ int d_abs(int x) {
	return x > 0 ? x : -x;
}

void convolve(Matrix& I, Matrix& K, Matrix& O, cudaStream_t* stream=nullptr) {
	//TODO : support different modes
	int w = I.size().w;
	int h = I.size().h;
	int r = K.size().w / 2;

	convolve_d(I.d_data(), K.d_data(), O.d_data(), w, h, r, stream);
}

void correlate(Matrix& I, Matrix& K, Matrix& O, cudaStream_t* stream=nullptr) {
	//TODO : support different modes
	int w = I.size().w;
	int h = I.size().h;
	int r = K.size().w / 2;

	correlate_d(I.d_data(), K.d_data(), O.d_data(), w, h, r,stream);
}

/*__device__ void submat_mul(double* a, double* b, double* o,
 int asrci, int asrcj, int aw,
 int bsrci, int bsrcj, int bw){

 auto i = threadIdx.y;
 auto j = threadIdx.x;
 auto w = blockDim.x;

 auto a_i = idx(asrci + i, asrcj + j, aw);
 auto b_i = idx(bsrci + i, bsrcj + j, bw);

 o[idx(i,j,w)] = a[a_i] * b[b_i];
 }*/


__global__ void safe_deconvolve(double* I, double* _G, double* dW, int w, int h){
	//int kw = blockDim.x;
	//int kh = blockDim.y; //kernel dimensions
	int r = blockDim.x / 2; //radius of kernel
	int ki = threadIdx.y;
	int kj = threadIdx.x;

	auto i_start = max(0, r - ki);
	auto j_start = max(0, r - kj);

	auto i_end = min(h, h + r - ki);
	auto j_end = min(w, w + r - kj);

	auto index = idx(ki,kj,2*r+1);

	dW[index] = 0;
	for(int i=i_start; i < i_end; ++i){
		for(int j=j_start; j < j_end; ++j){
			dW[index] += I[idx(i,j,w)] * _G[idx(i+(ki-r),j+(kj-r),w)];
		}
	}

}

__global__ void rapid_deconvolve(double* I, double* _G, double* dW, int w, int h){
	extern __shared__ double ddW[]; //dims same as I

	int kw = gridDim.x;
	int kh = gridDim.y;

	int kj = blockIdx.x;
	int ki = blockIdx.y;
	int r = kw / 2;
	//each block takes dW[ki][kj]

	auto i_start = max(0, r - ki);
	auto j_start = max(0, r - kj);
	auto i_end = min(h, h + r - ki);
	auto j_end = min(w, w + r - kj);
	int j = threadIdx.x;
	int i = threadIdx.y;

	auto index = idx(i,j,w);

	if(i_start<i && i<i_end && j_start<j && j<j_end)
		ddW[index] = I[index] * _G[idx(i+(ki-r),j+(kj-r),w)];
	else
		ddW[index] = 0; //out_of_bounds

	__syncthreads();

	//now accumulate ddW...
	auto n = blockDim.x * blockDim.y;
	int nTotalThreads = NearestPowerOf2(n);	// Total number of threads, rounded up to the next power of two

	while(nTotalThreads > 1)
	{
	  int halfPoint = (nTotalThreads >> 1);	// divide by two
	  // only the first half of the threads will be active.
	  if (index < halfPoint)
	  {
	   int index2 = index + halfPoint;
	   if (index2 < n)
	      ddW[index] += ddW[index2];
	  }
	  __syncthreads();
	  // Reducing the binary tree size by two:
	  nTotalThreads = halfPoint;
	}

	if(index == 0){
		//only 1 thread will write to dW
		dW[idx(ki,kj,kw)] = ddW[0]; //0 = final accumulated index
	}

}
void deconvolve(Matrix& I, Matrix& _G, Matrix& dW) {

	auto s = dW.size().w;
	auto r = dW.size().w / 2; //assume square kernel, odd-size

	if(I.size().wh > 1024){
		throw "TOO MANY THREADS!!";
	}

	//TRYING
	dim3 gridDims(s,s);
	dim3 blockDims(I.size().w, I.size().h);
	rapid_deconvolve<<<gridDims,blockDims,I.size().wh * sizeof(double)>>>(I.d_data(),_G.d_data(),dW.d_data(),I.size().w,I.size().h);
}

ConvolutionLayer::ConvolutionLayer(int d_out) : //TODO : accept kernel size
		d_out(d_out) {
	connection = nullptr;
	d_in = 0;
}

ConvolutionLayer::~ConvolutionLayer() {
	for (int i = 0; i < d_in; ++i) {
		delete connection[i];
	}
	delete[] connection;

	delete[] streams_i;
	delete[] streams_o;

}

void ConvolutionLayer::setup(Size& _s, int& _d) {
	//_d = depth of input

	s = _s;
	d_in = _d;

	streams_i = new cudaStream_t[d_in];
	for (int i = 0; i < d_in; ++i) {
		//I.push_back(Matrix(s));
		cudaStreamCreate(&streams_i[i]);
	}

	streams_o = new cudaStream_t[d_out];
	for (int o = 0; o < d_out; ++o) {
		O.push_back(Matrix(s)); //same size
		W.push_back(Matrix::rand(5, 5)); //5,5 = kernel size

		dW.push_back(Matrix::zeros(5, 5));
		dW_p.push_back(Matrix::zeros(5, 5)); //previous dW
		dW_t.push_back(Matrix::zeros(5,5)); //total over mini-batch

		G.push_back(Matrix::zeros(s));

		//Bias depends on output matrix size,
		//Which is equivalent to the input matrix size (in case of this convolution)
		B.push_back(Matrix::zeros(s));
		dB.push_back(Matrix::zeros(s));
		dB_p.push_back(Matrix::zeros(s)); //previous dB
		dB_t.push_back(Matrix::zeros(s)); // total over mini-batch

		cudaStreamCreate(&streams_o[o]);
	}

	connection = new bool*[d_out];

	for (int o = 0; o < d_out; ++o) {
		connection[o] = new bool[d_in];
		for (int i = 0; i < d_in; ++i) {
			//connection[o][i] = true;
			connection[o][i] = ((o % 3) == (i % 3));
			//partial connection
		}
	}
	_s = s; //same size, at least for current convolution function.
	_d = d_out;


}

std::vector<Matrix>& ConvolutionLayer::FF(std::vector<Matrix>& _I) {
	pI = &_I;
	/*for (int i = 0; i < d_in; ++i) {
		//_I[i].copyTo(I[i],&streams_i[i]);
		_I[i].copyTo(I[i]);
	}*/
	auto& I = *pI;

	Matrix tmp = Matrix(O[0].size());

	for (int o = 0; o < d_out; ++o) {
		O[o].zero(); //set to zero
		for (int i = 0; i < d_in; ++i) {
			if (connection[o][i]) {
				//TODO : this seems like it can be parallelized, like ""per each output layer...""
				//convolve(_I[i], W[o], tmp,&streams_i[i]);
				convolve(I[i], W[o], tmp);

				O[o] += tmp;
			}
		}
		O[o] += B[o]; //add bias
	}

	/*for(int i=0;i<d_in;++i){
		cudaStreamSynchronize(streams_i[i]);
	}*/
	return O;
}

std::vector<Matrix>& ConvolutionLayer::BP(std::vector<Matrix>& _G) {
	auto& I = *pI;
	auto iw = s.w;
	auto ih = s.h;

	auto fw = W[0].size().w; //kernel size
	auto fh = W[0].size().h;

	auto fwr = fw / 2; //kernel size
	auto fhr = fh / 2;

	for (int i = 0; i < d_in; ++i) {
		G[i].zero(); //reset to 0
	}

	Matrix dG(G[0].size()); //TODO : make this static?
	Matrix ddW(dW[0].size()); //there are acculumants.

	for (int o = 0; o < d_out; ++o) { //for each output channel(depth):
		dW[o].zero();
	}

	for(int o=0;o<d_out;++o){
		cudaStreamSynchronize(streams_o[o]);
	}

	for (int o = 0; o < d_out; ++o) { //for each output channel(depth):
		correlate(_G[o], W[o], dG);
		for (int i = 0; i < d_in; ++i) { //for each input channel
			if (connection[o][i]) { //if the channels are related..
				G[i] += dG;
				deconvolve(I[i], _G[o], ddW);
				dW[o] += ddW; //accum

				/*I[i].set_sync(false);
				_G[o].set_sync(false);
				ddW.set_sync(false);

				namedPrint(I[i]);
				namedPrint(_G[o]);
				namedPrint(ddW);
				*/
				/*if(isnan(ddW)){
					throw "CISNAN!";
				}*/
				//dW[o].set_sync(false);
			}
		}


		/*dW[o] = (dW_p[o] * MOMENTUM)
				+ (dW[o] * ETA) //no "gain" implemented yet
				- (W[o] * DECAY);

		dB[o] = (dB_p[o] * MOMENTUM)
				+ (_G[o] * ETA); //bias = gradient
				//- (B[o] * DECAY);
		*/
		//_G[o].copyTo(dB[o]);

		//dB[o] = _G[o];
		//dW[o].copyTo(dW_p[o]);
		//dB[o].copyTo(dB_p[o]);

		//accumulate to total

		dW_t[o] += dW[o];
		dB_t[o] += _G[o];

		//individual updates
		//W[o] += dW[o] * ETA;
		//B[o] += _G[o] * ETA;

		/*if(isnan(dW[o])){
			throw "DISNAN!";
		}*/
		//dW_p[o] = dW[o];
		//dB_p[o] = dB[o];
	}
	return G;
}

void ConvolutionLayer::update() {
	//minibatch-like
	for (int o = 0; o < d_out; ++o) {
		//dW_t[o] /= 128.0;
		//dB_t[o] /= 128.0; //batch size

		W[o] += (dW_p[o] * MOMENTUM) + \
				(dW_t[o] * ETA) - \
				(W[o] * DECAY);
		B[o] += (dB_p[o] * MOMENTUM) + \
				(dB_t[o] * ETA);
		dW_t[o].copyTo(dW_p[o]);
		dB_t[o].copyTo(dB_p[o]);

		dW_t[o].zero();
		dB_t[o].zero();
	}
}

void ConvolutionLayer::debug(){
	for(int o=0;o<d_out;++o){
		W[o].print(std::cout);
	}
}
