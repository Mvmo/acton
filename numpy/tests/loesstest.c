#include "../../builtin/builtin.h"
#include "../numpy.h"

$ndarray $pow3($Integral$ndarray wit, $ndarray x) {
  $ndarray tmp =  wit->$class->__mul__(wit,x,x);
  return wit->$class->__mul__(wit,tmp,x);
}

$ndarray loess_simple($ndarray x, $ndarray y, $ndarray xin, $int win) {
  $list ix = $NEW($list,NULL,NULL);
  $Slice s = $NEW($Slice,NULL,NULL,NULL);
  $list_append(ix,s);
  $list_append(ix,NULL);
  $Primitive witp = ($Primitive)$Primitive$float$witness;
  $Integral$ndarray wit = $NEW($Integral$ndarray,witp);
  $Minus$ndarray wit2 = wit-> w$Minus$Integral;
  $ndarray tmp1 = wit2->$class->__sub__(wit2,xin,$ndarray_getslice(x,ix));
  $ndarray xd = $ndarray_abs(witp,tmp1);
  $ndarray tmp2 = $ndarray_partition(witp,xd,win);
  $list ix2 = $NEW($list,NULL,NULL);
  $list_append(ix2,s);
  $list_append(ix2,win);
  $ndarray tmp3 = $ndarray_getslice(tmp2,ix2);
  $ndarray tmp4 = $ndarray_getslice(tmp3,ix);
  $ndarray tmp5 = wit->$class->__truediv__(wit,xd,tmp4);
  $ndarray w = $ndarray_clip(witp,tmp5,to$float(0.0),to$float(1.0));
  $ndarray tmp6 = $pow3(wit,w);
  $ndarray tmp7 = wit2->$class->__sub__(wit2,$ndarray_fromatom(to$float(1.0)),tmp6);
  $ndarray ws = $pow3(wit,tmp7);
  $ndarray a00 = $ndarray_sum(witp,ws,to$int(1));
  $ndarray a01 = $ndarray_dot(witp,ws,x);
  $ndarray a11 = $ndarray_dot(witp,ws,wit->$class->__mul__(wit,x,x));
  $ndarray b0 = $ndarray_dot(witp,ws,y);
  $ndarray b1 = $ndarray_dot(witp,ws,wit->$class->__mul__(wit,x,y));
  $ndarray det = wit2->$class->__sub__(wit2,wit->$class->__mul__(wit,a00,a11),wit->$class->__mul__(wit,a01,a01));
  $ndarray tmp8 = wit2->$class->__sub__(wit2,wit->$class->__mul__(wit,a11,b0),wit->$class->__mul__(wit,a01,b1));
  $ndarray tmp9 = wit2->$class->__sub__(wit2,wit->$class->__mul__(wit,a00,b1),wit->$class->__mul__(wit,a01,b0));
  $ndarray tmp10 = wit->$class->__add__(wit,tmp8,wit->$class->__mul__(wit,tmp9,xin));
  return wit->$class->__truediv__(wit,tmp10,det);
}

$ndarray mkarray(double elems[], int len){
  $list lst = $NEW($list,NULL,NULL);
  for (int i =0; i< len; i++)
    $list_append(lst,to$float(elems[i]));
  return $ndarray_array(($Primitive)$Primitive$float$witness,lst);
}
  
int main(int argc, char *argv[]) {
  long n;
  sscanf(argv[1],"%ld",&n);
  $ndarray xx,yy;
  long win;
  if (n <= 21) {
    
    double xx0[] = {0.5578196, 2.0217271, 2.5773252, 3.4140288, 4.3014084,
                    4.7448394, 5.1073781, 6.5411662, 6.7216176, 7.2600583,
                    8.1335874, 9.1224379, 11.9296663, 12.3797674, 13.2728619,
                    14.2767453, 15.3731026, 15.6476637, 18.5605355, 18.5866354,
                    18.7572812};
    double yy0[] = {18.63654, 103.49646, 150.35391, 190.51031, 208.70115,
                    213.71135, 228.49353, 233.55387, 234.55054, 223.89225,
                    227.68339, 223.91982, 168.01999, 164.95750, 152.61107,
                    160.78742, 168.55567, 152.42658, 221.70702, 222.69040,
                    243.18828};
    n = 21;
    win = 6;
    /*

    double xx0[] = {0.0,0.25,0.5,0.75,1.0};
    double yy0[] = {0.9,1.0,1.2,1.3,1.3};

    n = 5;
    win = 2;
    */
    xx = mkarray(xx0,n);
    yy = mkarray(yy0,n);
  } else {
    double xx0[n], yy0[n];
    double step = 2*3.1415926535/(n-1);
    for (int i=0; i<n; i++) {
      xx0[i] = i*step;
      yy0[i] = sin(i*step);
    }
    xx = mkarray(xx0,n);
    yy = mkarray(yy0,n);
    win = n/4-1;
  }
  $ndarray res = loess_simple(xx,yy,xx,to$int(win));
  printf("[ %0.3f %0.3f ... %0.3f %0.3f ]\n",res->data[0].d, res->data[1].d, res->data[n-2].d,
         res->data[n-1].d);
}


