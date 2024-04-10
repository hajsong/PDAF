import numpy as np

obsname = 'etan_obs'
tidx = np.arange(20, 121, 20)
mu, sigma = 0, 0.05

for i in tidx:
    fname = obsname + '.' + str(i).zfill(10)
    with open(fname, 'rb') as f:
        data = np.fromfile(f, '>f4')
    ival = np.where(data>-1e3)[0]
    prt = np.random.normal(mu, sigma, len(ival))
    data[ival] = data[ival] + prt
    f=open(fname, 'wb')
    data.astype('>f4').tofile(f)
    f.close()



